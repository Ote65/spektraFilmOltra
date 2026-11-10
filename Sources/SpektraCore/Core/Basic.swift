import Foundation

struct Vec3: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    subscript(index: Int) -> Double {
        get {
            switch index {
            case 0: return x
            case 1: return y
            default: return z
            }
        }
        set {
            switch index {
            case 0: x = newValue
            case 1: y = newValue
            default: z = newValue
            }
        }
    }

    static func + (lhs: Vec3, rhs: Vec3) -> Vec3 { Vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z) }
    static func * (lhs: Vec3, rhs: Vec3) -> Vec3 { Vec3(lhs.x * rhs.x, lhs.y * rhs.y, lhs.z * rhs.z) }
    static func * (lhs: Vec3, rhs: Double) -> Vec3 { Vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs) }
    static func / (lhs: Vec3, rhs: Double) -> Vec3 { Vec3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs) }
}

struct Mat3 {
    var m: [Double] // row-major 3x3

    init(_ m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    init(rows: [[Double]]) {
        precondition(rows.count == 3 && rows.allSatisfy { $0.count == 3 })
        self.m = rows.flatMap { $0 }
    }

    static let identity = Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    func apply(_ v: Vec3) -> Vec3 {
        Vec3(
            m[0] * v.x + m[1] * v.y + m[2] * v.z,
            m[3] * v.x + m[4] * v.y + m[5] * v.z,
            m[6] * v.x + m[7] * v.y + m[8] * v.z
        )
    }

    func inverted() -> Mat3 {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h
        let B = -(d * i - f * g)
        let C = d * h - e * g
        let det = a * A + b * B + c * C
        precondition(abs(det) > 1e-20)
        let invDet = 1.0 / det
        return Mat3([
            A * invDet, -(b * i - c * h) * invDet, (b * f - c * e) * invDet,
            B * invDet, (a * i - c * g) * invDet, -(a * f - c * d) * invDet,
            C * invDet, -(a * h - b * g) * invDet, (a * e - b * d) * invDet,
        ])
    }

    static func * (lhs: Mat3, rhs: Mat3) -> Mat3 {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var sum = 0.0
                for k in 0..<3 {
                    sum += lhs.m[r * 3 + k] * rhs.m[k * 3 + c]
                }
                out[r * 3 + c] = sum
            }
        }
        return Mat3(out)
    }
}

enum ResourceLocator {
    static var dataRoot: URL {
        if let override = ProcessInfo.processInfo.environment["SPEKTRA_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let resource = Bundle.main.resourceURL {
            return resource.appendingPathComponent("Data", isDirectory: true)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd.appendingPathComponent("Sources/SpektraCore/Resources/Data", isDirectory: true)
    }

    private static let lock = NSLock()
    private static var resolved: [String: URL] = [:]

    static func url(_ relative: String) -> URL {
        lock.lock()
        if let cached = resolved[relative] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let result = resolve(relative)
        lock.lock()
        resolved[relative] = result
        lock.unlock()
        return result
    }

    /// 仓库里目录名是小写（profiles / luts），代码里按 Profiles / LUTs 取。
    /// macOS 大小写不敏感掩盖了差异，iOS 的 APFS 会直接找不到，这里逐级做大小写不敏感解析。
    private static func resolve(_ relative: String) -> URL {
        let direct = dataRoot.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        var current = dataRoot
        for part in relative.split(separator: "/").map(String.init) {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
            if let match = items.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                current.appendPathComponent(match)
            } else {
                current.appendPathComponent(part)
            }
        }
        return current
    }
}

enum JSONHelpers {
    static func loadObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError.invalidJSON(url.lastPathComponent)
        }
        return object
    }

    static func doubleOrNaN(_ value: Any?) -> Double {
        guard let value, !(value is NSNull) else { return .nan }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let parsed = Double(string) { return parsed }
        return .nan
    }

    static func double(_ value: Any?, default fallback: Double = 0) -> Double {
        guard let value, !(value is NSNull) else { return fallback }
        if let number = value as? NSNumber { return number.doubleValue }
        return fallback
    }

    static func int(_ value: Any?, default fallback: Int = 0) -> Int {
        guard let value, !(value is NSNull) else { return fallback }
        if let number = value as? NSNumber { return number.intValue }
        return fallback
    }

    static func string(_ value: Any?, default fallback: String = "") -> String {
        guard let value, !(value is NSNull) else { return fallback }
        if let string = value as? String { return string }
        return fallback
    }

    static func bool(_ value: Any?, default fallback: Bool = false) -> Bool {
        guard let value, !(value is NSNull) else { return fallback }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return string == "true" }
        return fallback
    }

    static func doubleArray(_ value: Any?) -> [Double] {
        guard let array = value as? [Any] else { return [] }
        return array.map { doubleOrNaN($0) }
    }

    static func doubleMatrix(_ value: Any?) -> [[Double]] {
        guard let array = value as? [Any] else { return [] }
        return array.map { doubleArray($0) }
    }

    static func doubleTensor(_ value: Any?) -> [[[Double]]] {
        guard let array = value as? [Any] else { return [] }
        return array.map { doubleMatrix($0) }
    }
}

enum CoreError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case missingResource(String)
    case invalidProfile(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .invalidJSON(let name): return "Invalid JSON: \(name)"
        case .missingResource(let name): return "Missing resource: \(name)"
        case .invalidProfile(let name): return "Invalid profile: \(name)"
        case .unsupported(let message): return message
        }
    }
}

