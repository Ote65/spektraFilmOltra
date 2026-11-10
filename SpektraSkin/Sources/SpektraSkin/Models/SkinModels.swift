import Foundation
import AppKit

// MARK: - 共享值类型

enum ColorLabel: String, CaseIterable, Identifiable, Hashable {
    case red, yellow, green, blue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return "红"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        }
    }
}

struct PhotoItem: Identifiable, Hashable {
    let id: String
    let filename: String
    let asset: String
    let film: String
    let paper: String?
    let dimensions: String
    let isRaw: Bool
    let favorite: Bool
    let color: ColorLabel?
    let isGraded: Bool
    var thumbnailPath: String? = nil

    var metaLine: String {
        [film, dimensions].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var editorMetaLine: String {
        [dimensions, film, paper ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var aspectRatio: CGFloat {
        let parts = dimensions.split(separator: "×").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 4.0 / 3.0 }
        return CGFloat(parts[0] / parts[1])
    }

    var thumbnailImage: NSImage? {
        guard let thumbnailPath else { return nil }
        return ThumbnailImageCache.image(at: thumbnailPath)
    }
}

enum ThumbnailImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct FolderItem: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    let isCurrent: Bool
}

struct LibrarySnapshot {
    let folderCount: Int
    let photoCount: Int
    let sectionTitle: String
    let sectionCount: String
    let folders: [FolderItem]
    let photos: [PhotoItem]
    let statusMessage: String
    var currentID: String? = nil
}

// MARK: - 预设

enum FilmKind: Hashable {
    case negative
    case reversal
    case cinema
    case paper
}

struct PresetItem: Identifiable, Hashable {
    let id: String
    let name: String
    let meta: String
    let brand: String
    let kind: FilmKind
    let hue: Double
}

struct PresetCatalog {
    let films: [PresetItem]
    let papers: [PresetItem]
}

// MARK: - 快速控制

struct QuickAxis: Identifiable, Hashable {
    let id: String
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let decimals: Int
    let suffix: String
    let baseValue: Double
    let value: Double
    let unavailableReason: String?

    var isDirty: Bool { abs(value - baseValue) > 1e-9 }

    func text(for value: Double) -> String {
        let normalized = abs(value) < pow(10, Double(-decimals)) * 0.5 ? 0 : value
        var text = String(format: "%.\(decimals)f", normalized)
        if decimals > 0, text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if range.lowerBound < 0, normalized > 0 { text = "+" + text }
        return text + suffix
    }
}

struct QuickPad: Hashable {
    let title: String
    let x: Double
    let y: Double
}

struct QuickGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let axes: [QuickAxis]
    let pad: QuickPad?
}

// MARK: - 专业参数

enum ParamControl: Hashable {
    case slider(value: Double, valueText: String, dirty: Bool)
    case toggle(isOn: Bool)
    case choice(text: String)
}

struct ParamRow: Identifiable, Hashable {
    let id: String
    let label: String
    let control: ParamControl
    let isEnabled: Bool
}

struct ParamGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let rows: [ParamRow]
}

struct ParamPage: Identifiable, Hashable {
    let id: String
    let title: String
    let groups: [ParamGroup]
}

// MARK: - 显影

/// 渲染调度状态：对齐 electron 的「等待新参数 / 已中断 / 渲染中(进度)」。
struct RenderPhase: Hashable {
    enum State: Hashable {
        case idle
        case waiting
        case interrupted
        case rendering
    }

    var state: State = .idle
    var label: String = ""
    var index: Int = 0
    var total: Int = 0

    var isBusy: Bool {
        state != .idle
    }

    static let idle = RenderPhase()
}

struct HistogramData: Hashable {
    let red: [Double]
    let green: [Double]
    let blue: [Double]
}

// MARK: - 导出

enum ExportFormat: String, CaseIterable, Identifiable, Hashable {
    case tiff8
    case tiff16
    case tiff16ProPhoto
    case exrHalf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiff8: return "TIFF 8-bit（sRGB）"
        case .tiff16: return "TIFF 16-bit（sRGB）"
        case .tiff16ProPhoto: return "TIFF 16-bit（ProPhoto 线性）"
        case .exrHalf: return "EXR half（ACES 线性）"
        }
    }

    var shortTitle: String {
        switch self {
        case .tiff8: return "TIFF 8"
        case .tiff16: return "TIFF 16"
        case .tiff16ProPhoto: return "ProPhoto 16"
        case .exrHalf: return "EXR half"
        }
    }

    var fileExtension: String {
        switch self {
        case .tiff8, .tiff16, .tiff16ProPhoto: return "tif"
        case .exrHalf: return "exr"
        }
    }

    var bitDepth: Int {
        switch self {
        case .tiff8: return 8
        case .tiff16, .tiff16ProPhoto: return 16
        case .exrHalf: return 16
        }
    }

    var colorSpace: String? {
        switch self {
        case .tiff16ProPhoto: return "ProPhoto RGB"
        case .exrHalf: return "ACES2065-1"
        default: return nil
        }
    }

    var cctfEncoding: Bool? {
        switch self {
        case .tiff16ProPhoto, .exrHalf: return false
        default: return nil
        }
    }
}

struct ExportSettings: Equatable {
    var format: ExportFormat = .tiff16
    var longEdge: Int = 0
    var directory: URL?
    var filenameTemplate: String = "{name}-spektra"
}

struct EditorSnapshot {
    let photo: PhotoItem
    let filmName: String
    let paperName: String
    let filmstrip: [PhotoItem]
    let quickGroups: [QuickGroup]
    let proPages: [ParamPage]
    let histogram: HistogramData
    let dirtyCount: Int
    let currentFilmID: String
    let currentPaperID: String
    let stripCount: Int
    var previewImage: NSImage? = nil
    var originalImage: NSImage? = nil
    var previewScale: Double = 0.25
    var renderPhase: RenderPhase = .idle
    var previewIsPredicted: Bool = false
    var previewRevision: Int = 0
    var preflightNotice: String? = nil
}

struct GradeSnapshot {
    let photo: PhotoItem
    let handoffMeta: String
    var previewImage: NSImage? = nil
    var sourceReady: Bool = false
    var sourceSize: String = ""
    var analysis: ToneAnalysis? = nil
    var presets: [GradePreset] = []
    var luts: [GradeLUTEntry] = []
    var recipe = GradeRecipe()
    var phase: RenderPhase = .idle
    var histogram: HistogramData = PreviewData.histogram
    var statusMessage: String = ""
}

// MARK: - 后端边界
//
// 皮肤只依赖这一份只读快照协议。当前实现是静态预览数据；
// 未来 Swift 引擎实现同一协议后，视图代码不需要改。
protocol SpektraSkinDataSource {
    var library: LibrarySnapshot { get }
    var presets: PresetCatalog { get }
    func editor(for photoID: PhotoItem.ID) -> EditorSnapshot
    func grade(for photoID: PhotoItem.ID) -> GradeSnapshot
}

// 用户意图只通过这一层闭包离开皮肤。预览版全部为空实现；
// Swift 引擎接管后把这里接到渲染、导出和状态存储。
struct SkinActions {
    var openPhoto: (String) -> Void = { _ in }
    var backToLibrary: () -> Void = {}
    var openGrade: () -> Void = {}
    var backToEditor: () -> Void = {}
    var selectFilm: (String) -> Void = { _ in }
    var selectPaper: (String) -> Void = { _ in }
    var selectStripPhoto: (String) -> Void = { _ in }
    var resetParameters: () -> Void = {}
    var exportCurrent: () -> Void = {}
    var exportOptions: () -> Void = {}
    // 引擎回调（静态预览时保持空实现）
    var quickChanged: (String, Double) -> Void = { _, _ in }
    var padChanged: (Double, Double) -> Void = { _, _ in }
    var proChanged: (String, Double) -> Void = { _, _ in }
    var proToggled: (String, Bool) -> Void = { _, _ in }
    var importPhotos: () -> Void = {}
    var importFolder: () -> Void = {}
    var exportAs: (String) -> Void = { _ in }
    var exportWithSettings: (ExportSettings) -> Void = { _ in }
    var refreshExportPreflight: () -> Void = {}
    var gradeRecipeChanged: (GradeRecipe) -> Void = { _ in }
    var gradePresetSaved: (String, GradeRecipe) -> Void = { _, _ in }
    var gradePresetDeleted: (String) -> Void = { _ in }
    var gradeLUTImported: () -> Void = {}
    var gradeExport: (ExportSettings) -> Void = { _ in }
    var renderScaleChanged: (Double) -> Void = { _ in }
    var reRender: () -> Void = {}
    var toggleFavorite: (String) -> Void = { _ in }
    var setColorLabel: (String, ColorLabel?) -> Void = { _, _ in }
    var removePhoto: (String) -> Void = { _ in }

    static let preview = SkinActions()
}
