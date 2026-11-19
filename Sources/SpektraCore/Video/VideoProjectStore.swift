import Foundation

/// 视频工程的 JSON 索引与缓存目录。与照片库分离，避免视频污染照片库
/// （方案 7.2 / 8.1）。macOS 用 Application Support，iOS 用 Documents。
final class VideoProjectStore: @unchecked Sendable {
    private(set) var projects: [VideoProject] = []
    let root: URL

    private let indexURL: URL
    private let ioQueue = DispatchQueue(label: "spektrafilm.video.store", qos: .utility)
    private let lock = NSLock()

    init(root: URL? = nil) {
        if let root { self.root = root } else {
            #if os(macOS)
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.root = base.appendingPathComponent("Spektrafilm/Videos", isDirectory: true)
            #else
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.root = base.appendingPathComponent("Spektrafilm/Videos", isDirectory: true)
            #endif
        }
        self.indexURL = self.root.appendingPathComponent("projects.json")
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 索引

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([VideoProject].self, from: data) {
            projects = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(projects) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - 目录

    func projectDirectory(id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func sourceURL(id: String) -> URL {
        projectDirectory(id: id).appendingPathComponent("source.mov")
    }

    func proxyURL(id: String) -> URL {
        projectDirectory(id: id).appendingPathComponent("proxy.mov")
    }

    func prepareDirectory(id: String) -> URL {
        let dir = projectDirectory(id: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 导入（只做文件拷贝，元数据由 VideoProbe 填）

    /// 把源文件拷进沙盒，返回新的工程 ID。调用方负责生成 URL 与元数据。
    func copySource(from url: URL, id: String) throws -> URL {
        let dir = prepareDirectory(id: id)
        let dest = dir.appendingPathComponent("source.mov")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    func add(_ project: VideoProject) {
        lock.lock()
        projects.insert(project, at: 0)
        persist()
        lock.unlock()
    }

    func update(_ project: VideoProject) {
        lock.lock()
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else {
            lock.unlock()
            return
        }
        var copy = project
        copy.updatedAt = Date()
        projects[idx] = copy
        persist()
        lock.unlock()
    }

    func remove(_ id: String) {
        lock.lock()
        projects.removeAll { $0.id == id }
        persist()
        lock.unlock()
        let dir = projectDirectory(id: id)
        try? FileManager.default.removeItem(at: dir)
    }

    func project(id: String) -> VideoProject? {
        projects.first { $0.id == id }
    }
}
