import Foundation
import simd

// MARK: - 导出设置

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case hevcStandard
    case hevcHigh
    case proRes422LT

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hevcStandard: return "HEVC 10-bit · 40 Mbps（标准）"
        case .hevcHigh: return "HEVC 10-bit · 60 Mbps（高）"
        case .proRes422LT: return "ProRes 422 LT（母版）"
        }
    }

    var shortTitle: String {
        switch self {
        case .hevcStandard: return "HEVC 40M"
        case .hevcHigh: return "HEVC 60M"
        case .proRes422LT: return "ProRes LT"
        }
    }

    var fileExtension: String { "mov" }

    /// 估算码率（Mbps）；ProRes 422 LT 在 1080p24 约 102 Mbps。
    var bitrateMbps: Double {
        switch self {
        case .hevcStandard: return 40
        case .hevcHigh: return 60
        case .proRes422LT: return 102
        }
    }
}

struct VideoExportSettings: Codable, Equatable {
    var codec: VideoCodec = .hevcStandard
    var audioPassthrough: Bool = true
    /// 540p 代理片；0 表示使用源帧率的一半（最少 24fps）。
    var proxyFPS: Int = 24
    var proxySeconds: Double = 4.0

    /// 输出预估大小（MB），供 UI 明示颗粒与码率取舍。
    func estimatedSizeMB(duration: Double) -> Double {
        codec.bitrateMbps * duration / 8.0
    }
}

// MARK: - 工程

struct VideoProject: Codable, Identifiable {
    var id: String
    var displayName: String
    /// 源文件路径（导入时已拷贝到应用沙盒）。
    var sourcePath: String
    /// iOS 相册资源标识：用于把系统相册里的同一个视频映射回已有工程，
    /// 避免每次点开都重复导入。macOS 导入的文件为 nil。
    var sourceAssetID: String? = nil
    var duration: Double
    var fps: Double
    var pixelWidth: Int
    var pixelHeight: Int
    /// 与照片共用的非破坏编辑参数；视频端只复用 LUT 与参数模型。
    var edit = PhotoEdit()
    /// 全片锁定的测光参考时间（秒）。
    var referenceTime: Double = 0
    /// 代理片路径（相对工程根）。
    var proxyPath: String?
    var exportSettings = VideoExportSettings()
    var createdAt = Date()
    var updatedAt = Date()
    /// 与照片同一套库标记：收藏 / 颜色标签。
    var favorite = false
    var colorLabel: String? = nil

    init(id: String, displayName: String, sourcePath: String, duration: Double,
         fps: Double, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.duration = duration
        self.fps = fps
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, sourcePath, duration, fps, pixelWidth, pixelHeight
        case edit, referenceTime, proxyPath, exportSettings, createdAt, updatedAt
        case favorite, colorLabel
    }

    /// 逐字段解码：旧索引没有新字段时回退默认值，避免整份视频索引解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 24
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
        edit = try c.decodeIfPresent(PhotoEdit.self, forKey: .edit) ?? PhotoEdit()
        referenceTime = try c.decodeIfPresent(Double.self, forKey: .referenceTime) ?? 0
        proxyPath = try c.decodeIfPresent(String.self, forKey: .proxyPath)
        exportSettings = try c.decodeIfPresent(VideoExportSettings.self, forKey: .exportSettings)
            ?? VideoExportSettings()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        colorLabel = try c.decodeIfPresent(String.self, forKey: .colorLabel)
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }

    var resolutionText: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "—" }
        return "\(pixelWidth)×\(pixelHeight)"
    }

    var durationText: String {
        guard duration.isFinite, duration > 0 else { return "—" }
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - 进度

struct VideoProgress: Equatable {
    enum Stage: String {
        case idle
        case probing
        case baking
        case rendering
        case writing
        case exporting
        case finished
        case failed
        case cancelled
    }

    var stage: Stage = .idle
    var frameIndex: Int = 0
    var frameCount: Int = 0
    var message: String = ""

    var fraction: Double {
        guard frameCount > 0 else { return 0 }
        return min(1, max(0, Double(frameIndex) / Double(frameCount)))
    }

    var label: String {
        switch stage {
        case .idle: return "就绪"
        case .probing: return "读取视频信息"
        case .baking: return "烘焙 LUT"
        case .rendering: return "显影渲染"
        case .writing: return "写入成片"
        case .exporting: return "导出中"
        case .finished: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    static let idle = VideoProgress()
}

// MARK: - 帧渲染参数

/// 单帧渲染的全部 uniform；由 VideoLUTPayload + 帧号组装。
struct VideoFrameUniforms {
    var autoEV: Float = 0
    var cameraEV: Float = 0
    var exposureOffset: Float = 0
    var printOffset: Float = 0
    var frameSeed: UInt32 = 0
    var grainEnabled: Bool = false
    var grainAmplitude: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    var grainSigma: Float = 1
    var grainDensityMin: SIMD3<Float> = SIMD3<Float>(0.03, 0.03, 0.03)
    var grainUniformity: SIMD3<Float> = SIMD3<Float>(0.97, 0.99, 0.97)
    var halationStrength: Float = 0
    var halationTint = SIMD3<Float>(1.0, 0.52, 0.24)
    var diffusionStrength: Float = 0
    var usmStrength: Float = 0
    /// 显影强度：1 = 完整显影，0 = 原片。
    var developStrength: Float = 1
    /// 胶片宽容度补偿：0 = 关，1 = 最强（高光软压 + 阴影抬升）。
    var dynamicRange: Float = 0
    var gradeShadows: Float = 0
    var gradeHighlights: Float = 0
    var gradeBlacks: Float = 0
    var gradeWhites: Float = 0
    var gradeContrast: Float = 0
    var gradeSaturation: Float = 1
    /// 渲染像素 ÷ 成片像素：预览抽帧降分辨率时用它补偿颗粒高频层的物理尺度。
    var grainPixelScale: Float = 1
    /// 印相冷暖：-1…1，正值偏暖（显示域 R/B 互补增益）。
    var gradeTemperature: Float = 0
    /// 黑白模式：1 = 显影结果之后做亮度归一。显示域变换，不进 LUT 烘焙。
    var monochrome: Float = 0

    // ---- 物理颗粒（实验性）----
    /// 0 = 原 valueNoise 密度域颗粒；1 = 逐像素 Poisson-Binomial 卤化银粒子 + 微结构。
    var grainMode: UInt32 = 0
    /// 每像素有效粒子数（R/G/B），由 particleAreaUM2 与 pixelSizeUM 换算。
    var particleN: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    /// 归一化密度上限，odParticle = dMax / n。
    var particleDMax: Float = 2.2
    /// 团簇模糊 σ（px），dye-cloud blur + final blur 合并值。
    var particleBlurPx: Float = 0.65
    /// 微结构团簇 σ（px），<=0.05 时 shader 跳过。
    var particleMicroPx: Float = 0
}
