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
    /// 快速控制的基线（编码后的 PhotoEdit）；缺失时以当前 edit 为准。
    var quickBaselineData: Data? = nil

    static func == (lhs: LibraryPhoto, rhs: LibraryPhoto) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func makeParams() throws -> RuntimePhotoParams { try edit.runtimeParams() }
}

/// 照片库：索引持久化 + 原图拷贝 + 缩略图路径。
/// 主线程与后台缩略图/导出队列会并发访问，所有共享状态读写都在锁内。
final class LibraryStore {
    private let lock = NSRecursiveLock()
    private var _photos: [LibraryPhoto] = []
    /// 线程安全快照：调用方拿到的是值类型拷贝，不会与内部数组并发读写。
    var photos: [LibraryPhoto] {
        lock.lock()
        defer { lock.unlock() }
        return _photos
    }
    let root: URL
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
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryPhoto].self, from: data) else {
            _photos = []
            return
        }
        // 显影台只接受 RAW；旧索引里的 JPEG/TIFF 不再进入库。
        _photos = decoded.filter {
            ImageLoader.rawSuffixes.contains(
                URL(fileURLWithPath: $0.originalPath).pathExtension.lowercased()
            )
        }
    }

    func save() throws {
        lock.lock()
        defer { lock.unlock() }
        try saveLocked()
    }

    private func saveLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(_photos)
        try data.write(to: indexURL)
    }

    func originalURL(for photo: LibraryPhoto) -> URL {
        URL(fileURLWithPath: photo.originalPath)
    }

    func thumbnailURL(for photo: LibraryPhoto) -> URL? {
        photo.thumbnailPath.map { URL(fileURLWithPath: $0) }
    }

    @discardableResult
    func importPhoto(from source: URL) throws -> LibraryPhoto {
        let ext = source.pathExtension.lowercased()
        guard ImageLoader.rawSuffixes.contains(ext) else {
            throw NSError(domain: "Spektrafilm.Library", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "显影台只支持 RAW，拒绝导入 \(source.lastPathComponent)"])
        }
        let id = UUID().uuidString
        let destination = originalsURL.appendingPathComponent("\(id).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        let detected = ImageLoader.detectColorSpace(url: source)
        let dimensions = Self.pixelSize(url: destination)
        var edit = PhotoEdit()
        edit.io.inputColorSpace = detected.space
        edit.io.inputCCTFDecoding = detected.cctfDecoding
        let photo = LibraryPhoto(
            id: id,
            filename: source.lastPathComponent,
            originalPath: destination.path,
            thumbnailPath: nil,
            width: dimensions.width,
            height: dimensions.height,
            isRaw: true,
            edit: edit
        )
        lock.lock()
        defer { lock.unlock() }
        _photos.append(photo)
        try saveLocked()
        return photo
    }

    func update(_ photo: LibraryPhoto) throws {
        lock.lock()
        defer { lock.unlock() }
        if let index = _photos.firstIndex(where: { $0.id == photo.id }) {
            _photos[index] = photo
            try saveLocked()
        }
    }

    func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = _photos.firstIndex(where: { $0.id == id }) else { return }
        let photo = _photos[index]
        try? FileManager.default.removeItem(atPath: photo.originalPath)
        if let thumbnail = photo.thumbnailPath {
            try? FileManager.default.removeItem(atPath: thumbnail)
        }
        _photos.remove(at: index)
        try saveLocked()
    }

    func writeThumbnail(id: String, image: ImageRGB) throws {
        // 编码在锁外做，写回索引时再拿锁并确认照片仍在库中。
        let colorSpace: String
        let url: URL
        lock.lock()
        guard let index = _photos.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        colorSpace = _photos[index].edit.io.outputColorSpace
        url = thumbnailsURL.appendingPathComponent("\(id).png")
        lock.unlock()
        try ImageExport.save(image, to: url, bitDepth: 8, colorSpace: colorSpace)
        lock.lock()
        defer { lock.unlock() }
        guard let index = _photos.firstIndex(where: { $0.id == id }) else { return }
        _photos[index].thumbnailPath = url.path
        try saveLocked()
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
