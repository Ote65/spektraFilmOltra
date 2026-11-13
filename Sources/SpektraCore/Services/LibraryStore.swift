import Foundation
import ImageIO

/// 单张照片的非破坏编辑状态（不含 Profile 本体，只存 stock 名）。
struct PhotoEdit: Codable {
    var filmStock: String = "kodak_portra_400"
    var printStock: String = "kodak_supra_endura"
    var camera = CameraParams()
    var enlarger = EnlargerParams()
    var filmRender = FilmRenderParams()
    var printRender = PrintRenderParams()
    var scanner = ScannerParams()
    var io = IOParams()
    var settings = SettingsParams()
    var debug = DebugParams()
    var quickIntents: [String: Double] = [:]
    /// RAW 解码参数（白平衡/色温/色调/镜头校正）。改变后需要重新解码原图。
    var loadRaw = LoadRawParams()
    /// 手动旋转：0–3 表示顺时针 90° 的倍数；只改变几何方向，不重新解码。
    var rotationTurns = 0
    /// 黑白模式：移动端在显影结果之后做亮度归一，属于展示层的显影预设，不进入核心参数。
    var monochrome = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case filmStock, printStock, camera, enlarger, filmRender, printRender
        case scanner, io, settings, debug, quickIntents, loadRaw, rotationTurns
        case monochrome
    }

    /// 逐字段解码：旧索引缺少新字段时回退默认值，避免整库解码失败后读成空库。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filmStock = try container.decodeIfPresent(String.self, forKey: .filmStock) ?? "kodak_portra_400"
        printStock = try container.decodeIfPresent(String.self, forKey: .printStock) ?? "kodak_supra_endura"
        camera = try container.decodeIfPresent(CameraParams.self, forKey: .camera) ?? CameraParams()
        enlarger = try container.decodeIfPresent(EnlargerParams.self, forKey: .enlarger) ?? EnlargerParams()
        filmRender = try container.decodeIfPresent(FilmRenderParams.self, forKey: .filmRender) ?? FilmRenderParams()
        printRender = try container.decodeIfPresent(PrintRenderParams.self, forKey: .printRender) ?? PrintRenderParams()
        scanner = try container.decodeIfPresent(ScannerParams.self, forKey: .scanner) ?? ScannerParams()
        io = try container.decodeIfPresent(IOParams.self, forKey: .io) ?? IOParams()
        settings = try container.decodeIfPresent(SettingsParams.self, forKey: .settings) ?? SettingsParams()
        debug = try container.decodeIfPresent(DebugParams.self, forKey: .debug) ?? DebugParams()
        quickIntents = try container.decodeIfPresent([String: Double].self, forKey: .quickIntents) ?? [:]
        loadRaw = try container.decodeIfPresent(LoadRawParams.self, forKey: .loadRaw) ?? LoadRawParams()
        rotationTurns = try container.decodeIfPresent(Int.self, forKey: .rotationTurns) ?? 0
        monochrome = try container.decodeIfPresent(Bool.self, forKey: .monochrome) ?? false
    }

    /// RAW 解码选项：白平衡/色温/色调/镜头校正。解码尺寸由调用方另行传入。
    func rawDecoderOptions() -> RawDecoder.Options {
        var options = RawDecoder.Options()
        options.whiteBalance = loadRaw.whiteBalance
        options.temperature = loadRaw.temperature
        options.tint = loadRaw.tint
        options.lensCorrection = loadRaw.lensCorrection
        return options
    }

    func runtimeParams() throws -> RuntimePhotoParams {
        var params = RuntimePhotoParams(
            film: try ProfileStore.load(filmStock),
            print: try ProfileStore.load(printStock)
        )
        params.camera = camera
        params.enlarger = enlarger
        params.filmRender = filmRender
        params.printRender = printRender
        params.scanner = scanner
        params.io = io
        params.settings = settings
        params.debug = debug
        return params
    }
}

struct LibraryPhoto: Codable, Identifiable, Hashable {
    var id: String
    var filename: String
    var originalPath: String
    var thumbnailPath: String?
    var width: Int
    var height: Int
    var isRaw: Bool
    var favorite: Bool = false
    var colorLabel: String?
    var importedAt: Date = Date()
    var edit = PhotoEdit()
    /// 导入时的初始编辑状态：重置调色时用它还原，避免把拍摄曝光等出厂值一起抹掉。
    var initialEditData: Data? = nil
    /// 快速控制的基线（编码后的 PhotoEdit）；缺失时以当前 edit 为准。
    var quickBaselineData: Data? = nil
    /// 片边参数（移动端展示层配置，不参与核心显影，也不进交接图）。
    var borderData: Data? = nil
    /// 裁切与校正几何（移动端调色台配置，作用于交接图本身，片边后再合成）。
    var cropData: Data? = nil

    static func == (lhs: LibraryPhoto, rhs: LibraryPhoto) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func makeParams() throws -> RuntimePhotoParams { try edit.runtimeParams() }
}

/// 照片库：索引持久化 + 原图拷贝 + 缩略图路径。
/// `stageImport` / `writeThumbnailFile` 只做文件读写，不触碰 `photos`，可在后台线程调用；
/// `photos` 的读写仍然由拥有线程（移动端为主线程）负责。
final class LibraryStore: @unchecked Sendable {
    private(set) var photos: [LibraryPhoto] = []
    let root: URL
    private let ioQueue = DispatchQueue(label: "spektrafilm.library.io", qos: .utility)
    /// 缩略图批量写回时合并落盘：连续完成只编码一次整库索引。
    private let persistLock = NSLock()
    private var pendingThumbnailPersist: DispatchWorkItem?
    /// 移动端打开「支持 JPEG」后需要保留编码图记录，桌面端仍只保留 RAW。
    private let keepsEncodedRecords: Bool
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var originalsURL: URL { root.appendingPathComponent("Originals", isDirectory: true) }
    private var thumbnailsURL: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }

    init(root: URL? = nil, keepsEncodedRecords: Bool = false) {
        self.keepsEncodedRecords = keepsEncodedRecords
        let base = root ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Spektrafilm/Library", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryPhoto].self, from: data) else {
            photos = []
            return
        }
        // 移动端要保留编码图记录（关掉「支持 JPEG」时只在主页隐藏）；
        // 桌面端维持只收 RAW，避免历史索引里的编码图重新出现在库中。
        photos = keepsEncodedRecords ? decoded : decoded.filter {
            ImageLoader.rawSuffixes.contains(
                URL(fileURLWithPath: $0.originalPath).pathExtension.lowercased()
            )
        }
    }

    func save() throws {
        // 所有索引写入共用同一条串行队列：同步写会排在已入队的异步快照之后执行。
        // 否则旧快照可能晚于新索引落盘，表现为导入的照片从索引消失、或移除的照片复活。
        let snapshot = photos
        var failure: Error?
        ioQueue.sync {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: indexURL, options: .atomic)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// 参数类更新：先快照，再异步写索引。主线程不再做 JSON 编码与磁盘 IO，
    /// 拖动滑条时每 0.7 秒一次的落盘不会再卡住手势。
    /// 异步写与 `save()` 共用 `ioQueue`，因此调用顺序就是落盘顺序。
    func saveAsync() {
        persistIndexAsync()
    }

    private func persistIndexAsync() {
        let snapshot = photos
        let url = indexURL
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func originalURL(for photo: LibraryPhoto) -> URL {
        Self.resolve(photo.originalPath, root: root, folder: "Originals")
    }

    func thumbnailURL(for photo: LibraryPhoto) -> URL? {
        photo.thumbnailPath.map { Self.resolve($0, root: root, folder: "Thumbnails") }
    }

    /// 索引里存相对路径（Originals/…）；老索引是绝对路径，容器目录一变就失效，
    /// 这里按目录段重新定位，避免 App 更新后整库「找不到原图」。
    static func resolve(_ storedPath: String, root: URL, folder: String) -> URL {
        if storedPath.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: storedPath)
            if FileManager.default.fileExists(atPath: absolute.path) { return absolute }
            if let range = storedPath.range(of: "/\(folder)/") {
                let name = String(storedPath[range.upperBound...])
                return root.appendingPathComponent(folder).appendingPathComponent(name)
            }
            return absolute
        }
        return root.appendingPathComponent(storedPath)
    }

    /// 后台入库的中间态：只含准备阶段的产物，不持有库状态。
    struct StagedImport {
        let id: String
        let filename: String
        let originalPath: String
        let copiedFile: URL
        let width: Int
        let height: Int
        let colorSpace: String
        let cctfDecoding: Bool
        /// 相机内写入 RAW 的曝光补偿，入库时恢复，保证显影台与相册观感一致。
        let exposureBias: Double
    }

    /// 允许入库的扩展名：默认仅 RAW；打开「支持 JPEG」后放行所有可显影的编码图
    /// （JPEG / HEIC / PNG / TIFF…）。这样主页「全部 / 收藏」才能完整映射系统相册，
    /// 不会在 JPEG 模式下看起来只剩 RAW。
    static func accepts(_ source: URL, allowingEncoded: Bool) -> Bool {
        let ext = source.pathExtension.lowercased()
        if ImageLoader.rawSuffixes.contains(ext) { return true }
        return allowingEncoded && ImageLoader.encodedSuffixes.contains(ext)
    }

    /// 只做耗时准备（RAW 头解析 + 文件复制），不读写 `photos`，可在任意线程调用。
    func stageImport(from source: URL, allowingEncoded: Bool = false) throws -> StagedImport {
        let ext = source.pathExtension.lowercased()
        guard Self.accepts(source, allowingEncoded: allowingEncoded) else {
            throw NSError(domain: "Spektrafilm.Library", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "显影台只支持 RAW，拒绝导入 \(source.lastPathComponent)"])
        }
        let detected = ImageLoader.detectColorSpace(url: source)
        let dimensions = Self.pixelSize(url: source)
        let bias = ImageLoader.capturedExposureBias(url: source)
        let id = UUID().uuidString
        let copiedFile = originalsURL.appendingPathComponent("\(id).\(ext)")
        try FileManager.default.copyItem(at: source, to: copiedFile)
        return StagedImport(id: id,
                            filename: source.lastPathComponent,
                            originalPath: "Originals/\(id).\(ext)",
                            copiedFile: copiedFile,
                            width: dimensions.width,
                            height: dimensions.height,
                            colorSpace: detected.space,
                            cctfDecoding: detected.cctfDecoding,
                            exposureBias: bias)
    }

    /// 提交 `stageImport` 的产物：查重、追加到库并落盘。必须在库的拥有线程（主线程）调用。
    /// `persist == false` 用于批量导入：由调用方在整批结束后统一 `save()` 一次。
    @discardableResult
    func commitImport(_ staged: StagedImport, persist: Bool = true) throws -> LibraryPhoto {
        // 同名 + 同尺寸视为同一张：重复导入不再产生副本（相册选取与验收脚本都会重复触发）。
        if let existing = photos.first(where: {
            $0.filename == staged.filename
                && $0.width == staged.width && $0.height == staged.height
        }) {
            try? FileManager.default.removeItem(at: staged.copiedFile)
            return existing
        }
        var edit = PhotoEdit()
        edit.io.inputColorSpace = staged.colorSpace
        edit.io.inputCCTFDecoding = staged.cctfDecoding
        // 相机内调过的曝光已写进 RAW 的感光数据；显影管线的自动曝光会把它归一化掉，
        // 这里把拍摄时的补偿读回来重新施加，让显影台与导出和相册观感一致。
        if abs(staged.exposureBias) > 0.01 {
            edit.camera.exposureCompensationEV = staged.exposureBias
        }
        let photo = LibraryPhoto(
            id: staged.id,
            filename: staged.filename,
            originalPath: staged.originalPath,
            thumbnailPath: nil,
            width: staged.width,
            height: staged.height,
            isRaw: ImageLoader.rawSuffixes.contains(
                URL(fileURLWithPath: staged.originalPath).pathExtension.lowercased()
            ),
            edit: edit,
            initialEditData: try? JSONEncoder().encode(edit)
        )
        photos.append(photo)
        if persist { try save() }
        return photo
    }

    @discardableResult
    func importPhoto(from source: URL, allowingEncoded: Bool = false) throws -> LibraryPhoto {
        let ext = source.pathExtension.lowercased()
        guard Self.accepts(source, allowingEncoded: allowingEncoded) else {
            throw NSError(domain: "Spektrafilm.Library", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "显影台只支持 RAW，拒绝导入 \(source.lastPathComponent)"])
        }
        let detected = ImageLoader.detectColorSpace(url: source)
        let dimensions = Self.pixelSize(url: source)
        // 同名 + 同尺寸视为同一张：重复导入不再产生副本（相册选取与验收脚本都会重复触发）。
        if let existing = photos.first(where: {
            $0.filename == source.lastPathComponent
                && $0.width == dimensions.width && $0.height == dimensions.height
        }) {
            return existing
        }
        let id = UUID().uuidString
        let destination = originalsURL.appendingPathComponent("\(id).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        var edit = PhotoEdit()
        edit.io.inputColorSpace = detected.space
        edit.io.inputCCTFDecoding = detected.cctfDecoding
        // 相机内调过的曝光已写进 RAW 的感光数据；显影管线的自动曝光会把它归一化掉，
        // 这里把拍摄时的补偿读回来重新施加，让显影台与导出和相册观感一致。
        let bias = ImageLoader.capturedExposureBias(url: source)
        if abs(bias) > 0.01 {
            edit.camera.exposureCompensationEV = bias
        }
        let photo = LibraryPhoto(
            id: id,
            filename: source.lastPathComponent,
            originalPath: "Originals/\(id).\(ext)",
            thumbnailPath: nil,
            width: dimensions.width,
            height: dimensions.height,
            isRaw: ImageLoader.rawSuffixes.contains(ext),
            edit: edit,
            initialEditData: try? JSONEncoder().encode(edit)
        )
        photos.append(photo)
        try save()
        return photo
    }

    func update(_ photo: LibraryPhoto) throws {
        if let index = photos.firstIndex(where: { $0.id == photo.id }) {
            photos[index] = photo
            persistIndexAsync()
        }
    }

    func remove(id: String) throws {
        try remove(ids: [id])
    }

    /// 批量删除：一次移除全部记录、只落盘一次，再逐个清理原图与缩略图。
    /// 多选删除时避免每张都做一次整库 JSON 编码与同步写盘。
    func remove(ids: [String]) throws {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return }
        let removed = photos.filter { idSet.contains($0.id) }
        guard !removed.isEmpty else { return }
        let previous = photos
        photos.removeAll { idSet.contains($0.id) }
        // 先把索引落盘，再删文件：索引写失败时回滚内存记录，避免 UI 与磁盘分叉。
        do {
            try save()
        } catch {
            photos = previous
            throw error
        }
        for photo in removed {
            try? FileManager.default.removeItem(at: originalURL(for: photo))
            if let thumbnail = photo.thumbnailPath {
                try? FileManager.default.removeItem(
                    at: Self.resolve(thumbnail, root: root, folder: "Thumbnails"))
            }
        }
    }

    func writeThumbnail(id: String, image: ImageRGB) throws {
        guard let photo = photos.first(where: { $0.id == id }) else { return }
        let path = try writeThumbnailFile(
            id: id, image: image, colorSpace: photo.edit.io.outputColorSpace)
        commitThumbnail(id: id, relativePath: path, coalesce: false)
    }

    /// 后台写缩略图文件：只做编码与磁盘写入，不读写 `photos`，可在任意线程调用。
    /// 返回相对路径，调用方需在主线程调用 `commitThumbnail` 更新索引。
    func writeThumbnailFile(id: String, image: ImageRGB, colorSpace: String) throws -> String {
        let url = thumbnailsURL.appendingPathComponent("\(id).png")
        try ImageExport.save(image, to: url, bitDepth: 8, colorSpace: colorSpace)
        return "Thumbnails/\(id).png"
    }

    /// 在主线程把后台写好的缩略图路径写回库。
    /// `coalesce` 为 true 时把索引写入合并到一次延迟任务，避免批量补缩略图时
    /// 每张都重新编码整个 photos 数组。
    func commitThumbnail(id: String, relativePath: String, coalesce: Bool = true) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].thumbnailPath = relativePath
        if coalesce {
            scheduleIndexPersist()
        } else {
            persistIndexAsync()
        }
    }

    private func scheduleIndexPersist() {
        persistLock.lock()
        pendingThumbnailPersist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistLock.lock()
            self.pendingThumbnailPersist = nil
            self.persistLock.unlock()
            self.persistIndexAsync()
        }
        pendingThumbnailPersist = work
        persistLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    static func pixelSize(url: URL) -> (width: Int, height: Int) {
        // iOS 的 ImageIO 对部分索尼 ARW 会把 index 0 报告成内嵌预览（如 1616×1080），
        // 直接用它会让「原图长边」变成预览长边，导出选最大尺寸也只有 1080。
        // TIFF 系 RAW 先扫描 IFD/SubIFD，取真实的最大图像尺寸。
        if ImageLoader.rawSuffixes.contains(url.pathExtension.lowercased()),
           let raw = RawTIFFDimensions.pixelSize(url: url) {
            return raw
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any] else { return (0, 0) }
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        return (width, height)
    }

    /// 直接扫描 TIFF IFD / SubIFD 的 RAW 尺寸。
    ///
    /// 不依赖 CIRAWFilter（模拟器上查询 RAW 描述会长时间不返回），也不依赖
    /// ImageIO 的 index 0 属性；ARW / NEF / CR2 / DNG 等 TIFF 系 RAW 都适用。
    private enum RawTIFFDimensions {
        static func pixelSize(url: URL) -> (width: Int, height: Int)? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }

            let little: Bool
            if header[0] == 0x49, header[1] == 0x49 {
                little = true
            } else if header[0] == 0x4D, header[1] == 0x4D {
                little = false
            } else {
                return nil
            }
            guard u16(header, 2, little) == 42 else { return nil }
            let first = Int(u32(header, 4, little))
            guard first > 0 else { return nil }

            var best = (width: 0, height: 0)
            var visited = Set<Int>()

            func read(_ offset: Int, depth: Int) {
                guard depth <= 8, offset > 0, offset < 1 << 30,
                      !visited.contains(offset) else { return }
                visited.insert(offset)
                guard let countData = Self.read(handle, at: offset, length: 2) else { return }
                let entryCount = u16(countData, 0, little)
                guard entryCount > 0, entryCount < 512 else { return }
                let n = Int(entryCount)
                guard let data = Self.read(handle, at: offset + 2, length: n * 12 + 4) else { return }

                var width = 0
                var height = 0
                var children: [Int] = []

                for index in 0..<n {
                    let p = index * 12
                    let tag = u16(data, p, little)
                    let type = u16(data, p + 2, little)
                    let count = Int(u32(data, p + 4, little))
                    let value = Int(u32(data, p + 8, little))

                    if type == 3, count == 1 {
                        let short = Int(u16(data, p + 8, little))
                        if tag == 0x0100 { width = short }
                        if tag == 0x0101 { height = short }
                    } else if type == 4, count == 1 {
                        if tag == 0x0100 { width = value }
                        if tag == 0x0101 { height = value }
                    }

                    if tag == 0x014A || tag == 0x8769 {
                        if count <= 1 {
                            children.append(value)
                        } else if let list = Self.read(handle, at: value, length: count * 4) {
                            for child in 0..<count {
                                children.append(Int(u32(list, child * 4, little)))
                            }
                        }
                    }
                }

                if width > 0, height > 0,
                   width * height > best.width * best.height {
                    best = (width, height)
                }

                let next = Int(u32(data, n * 12, little))
                if next > 0 { read(next, depth: depth) }
                for child in children where child > 0 {
                    read(child, depth: depth + 1)
                }
            }

            read(first, depth: 0)
            return best.width > 0 && best.height > 0 ? best : nil
        }

        private static func read(_ handle: FileHandle, at offset: Int, length: Int) -> Data? {
            guard offset >= 0, length > 0, length <= 1 << 20 else { return nil }
            do {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: length)
            } catch {
                return nil
            }
        }

        private static func u16(_ data: Data, _ offset: Int, _ little: Bool) -> UInt16 {
            guard offset >= 0, offset + 2 <= data.count else { return 0 }
            let b0 = UInt16(data[offset])
            let b1 = UInt16(data[offset + 1])
            return little ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
        }

        private static func u32(_ data: Data, _ offset: Int, _ little: Bool) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            return little
                ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
                : ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
        }
    }
}
