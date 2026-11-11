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
final class LibraryStore {
    private(set) var photos: [LibraryPhoto] = []
    let root: URL
    private let ioQueue = DispatchQueue(label: "spektrafilm.library.io", qos: .utility)
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var originalsURL: URL { root.appendingPathComponent("Originals", isDirectory: true) }
    private var thumbnailsURL: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }

    init(root: URL? = nil) {
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
        // 显影台只接受 RAW；旧索引里的 JPEG/TIFF 不再进入库。
        photos = decoded.filter {
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
    }

    /// 只做耗时准备（RAW 头解析 + 文件复制），不读写 `photos`，可在任意线程调用。
    func stageImport(from source: URL) throws -> StagedImport {
        let ext = source.pathExtension.lowercased()
        guard ImageLoader.rawSuffixes.contains(ext) else {
            throw NSError(domain: "Spektrafilm.Library", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "显影台只支持 RAW，拒绝导入 \(source.lastPathComponent)"])
        }
        let detected = ImageLoader.detectColorSpace(url: source)
        let dimensions = Self.pixelSize(url: source)
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
                            cctfDecoding: detected.cctfDecoding)
    }

    /// 提交 `stageImport` 的产物：查重、追加到库并落盘。必须在库的拥有线程（主线程）调用。
    @discardableResult
    func commitImport(_ staged: StagedImport) throws -> LibraryPhoto {
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
        let photo = LibraryPhoto(
            id: staged.id,
            filename: staged.filename,
            originalPath: staged.originalPath,
            thumbnailPath: nil,
            width: staged.width,
            height: staged.height,
            isRaw: true,
            edit: edit,
            initialEditData: try? JSONEncoder().encode(edit)
        )
        photos.append(photo)
        try save()
        return photo
    }

    @discardableResult
    func importPhoto(from source: URL) throws -> LibraryPhoto {
        let ext = source.pathExtension.lowercased()
        guard ImageLoader.rawSuffixes.contains(ext) else {
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
            isRaw: true,
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
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let photo = photos[index]
        photos.remove(at: index)
        // 先把索引落盘，再删文件：索引写失败时不会留下指向已删原图的条目。
        try save()
        try? FileManager.default.removeItem(at: originalURL(for: photo))
        if let thumbnail = photo.thumbnailPath {
            try? FileManager.default.removeItem(at: Self.resolve(thumbnail, root: root, folder: "Thumbnails"))
        }
    }

    func writeThumbnail(id: String, image: ImageRGB) throws {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let url = thumbnailsURL.appendingPathComponent("\(id).png")
        try ImageExport.save(image, to: url, bitDepth: 8,
                             colorSpace: photos[index].edit.io.outputColorSpace)
        photos[index].thumbnailPath = "Thumbnails/\(id).png"
        persistIndexAsync()
    }

    static func pixelSize(url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any] else { return (0, 0) }
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        return (width, height)
    }
}
