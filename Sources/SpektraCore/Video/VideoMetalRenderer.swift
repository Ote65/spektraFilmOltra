import Foundation
import Metal
import CoreVideo
import simd

/// Metal 设备/管线/纹理缓存，单帧渲染（方案 2.2）。
///
/// 采用 CVPixelBuffer → CVMetalTextureCache → Metal → CVPixelBuffer 的
/// 零拷贝链路。输入 8-bit BGRA（Rec.709），输出 8-bit BGRA 给 AVAssetWriter；
/// 中间在 float16 线性域运算，避免 8-bit LUT 查表的量化误差。
protocol VideoRendering: AnyObject {
    var hasLUT: Bool { get }
    func installLUT(_ payload: VideoLUTPayload)
    func render(source: CVPixelBuffer, destination: CVPixelBuffer,
                uniforms: VideoFrameUniforms, payload: VideoLUTPayload) throws
}

final class VideoMetalRenderer: VideoRendering {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let library: MTLLibrary

    private var pipelineDevelop: MTLComputePipelineState
    private var pipelineBloomDown: MTLComputePipelineState
    private var pipelineBloomH: MTLComputePipelineState
    private var pipelineBloomV: MTLComputePipelineState
    private var pipelineComposite: MTLComputePipelineState
    // 物理颗粒链（grainMode=1）
    private var pipelineDevelopPre: MTLComputePipelineState
    private var pipelineGrainSample: MTLComputePipelineState
    private var pipelineGrainBlurH: MTLComputePipelineState
    private var pipelineGrainBlurV: MTLComputePipelineState
    private var pipelineDevelopPost: MTLComputePipelineState

    private var lutTextures: [MTLTexture]?
    private var lutSize: Int = 0
    private var uniformBuffer: MTLBuffer
    /// LUT 上传锁。
    private let lock = NSLock()
    /// 整帧渲染串行锁：预览 developStill（主线程）与导出 render（串行队列）
    /// 共用同一个 renderer 实例；uniformBuffer 与下面的复用池都是单例可变状态，
    /// 必须串行化，否则两帧会互相覆盖 uniform 并抢占同一批纹理。
    private let renderLock = NSLock()

    /// 每帧中间纹理复用池。之前每帧 makeTexture 7 张全/半尺寸 rgba32Float，
    /// 4K 单帧 GPU 纹理峰值约 601MB；复用后按尺寸常驻，不再随帧数反复分配。
    private struct ScratchTextures {
        let width: Int
        let height: Int
        /// 主链线性缓冲，必须 rgba32Float（色彩 parity 门禁），不动。
        let linear: MTLTexture
        let bloomA: MTLTexture
        let bloomB: MTLTexture
        let bloomC: MTLTexture
        /// 物理颗粒链 3 张：密度与增量值域 [0,1] / ±0.03，rgba16Float 足够，
        /// 比 32F 省一半（4K 3 张 380MB → 190MB）。nil = 尚未为物理模式建。
        let density: MTLTexture?
        let grainA: MTLTexture?
        let grainB: MTLTexture?

        var hasPhysical: Bool { density != nil && grainA != nil && grainB != nil }
    }
    private var scratch: ScratchTextures?


    /// MSL 的 FrameParams 必须与 shader 内声明严格同布局（见 VideoShaders）。
    /// 全部字段用定长标量与 simd 向量，保证 offset 与 MSL 一致。
    private struct FrameParams {
        var lutSize: UInt32 = 65
        var shaperLoEV: Float = -8
        var invSpan1: Float = 0
        var encodedMax: Float = 2
        var encodedInput: UInt32 = 0
        var autoEV: Float = 0
        var cameraOffset: Float = 0
        var printOffset: Float = 0
        var grainSigma: Float = 1
        var frameSeed: UInt32 = 0
        var grainR: Float = 0
        var grainG: Float = 0
        var grainB: Float = 0
        var densMinR: Float = 0.03
        var densMinG: Float = 0.03
        var densMinB: Float = 0.03
        var halation: Float = 0
        var diffusion: Float = 0
        var usm: Float = 0
        var padA: Float = 0
        // 矩阵四字段用 SIMD4：MSL float3 步长实测为 16 字节，SIMD4<Float> 同为 16 字节，
        // 两者偏移严格对齐（m0=80/m1=96/m2=112/tint=128/width=144…gradeTemperature=196）。
        // 之前误判 SIMD3 是 12 字节导致的「错位」其实是误诊——SIMD3 在 Swift 里 stride 也是 16；
        // 参数真正生效靠的是新增 gradeTemperature uniform + frameUniforms 映射 + edit 透传。
        var m0 = SIMD4<Float>(1, 0, 0, 0)
        var m1 = SIMD4<Float>(0, 1, 0, 0)
        var m2 = SIMD4<Float>(0, 0, 1, 0)
        var tint = SIMD4<Float>(1, 0.52, 0.24, 0)
        var width: UInt32 = 0
        var height: UInt32 = 0
        var padB: UInt32 = 0
        var padC: UInt32 = 0
        // 显影 / 影调（显示域后处理）
        var developStrength: Float = 1
        var dynamicRange: Float = 0
        var gradeShadows: Float = 0
        var gradeHighlights: Float = 0
        var gradeBlacks: Float = 0
        var gradeWhites: Float = 0
        var gradeContrast: Float = 0
        var gradeSaturation: Float = 1
        var grainPixelScale: Float = 1
        var gradeTemperature: Float = 0
        // 物理颗粒（对齐 MSL FrameParams 200–244）
        var grainMode: UInt32 = 0
        var particleN0: Float = 0
        var particleN1: Float = 0
        var particleN2: Float = 0
        var particleDMax: Float = 2.2
        var particleBlurPx: Float = 0.65
        var particleMicroPx: Float = 0
        var unifR: Float = 0.97
        var unifG: Float = 0.99
        var unifB: Float = 0.97
        var padE0: Float = 0
        var padE1: Float = 0
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VideoError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw VideoError.metalInit("无法创建 command queue")
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw VideoError.metalInit("无法创建纹理缓存")
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: VideoShaders.source, options: nil)
        } catch {
            throw VideoError.metalInit("MSL 编译失败: \(error.localizedDescription)")
        }
        func pipe(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                throw VideoError.metalInit("缺少 kernel \(name)")
            }
            return try device.makeComputePipelineState(function: fn)
        }
        self.device = device
        self.commandQueue = queue
        self.textureCache = cache
        self.library = library
        self.pipelineDevelop = try pipe("develop")
        self.pipelineBloomDown = try pipe("bloomDownsample")
        self.pipelineBloomH = try pipe("bloomH")
        self.pipelineBloomV = try pipe("bloomV")
        self.pipelineComposite = try pipe("composite")
        self.pipelineDevelopPre = try pipe("developPre")
        self.pipelineGrainSample = try pipe("grainSample")
        self.pipelineGrainBlurH = try pipe("grainBlurH")
        self.pipelineGrainBlurV = try pipe("grainBlurV")
        self.pipelineDevelopPost = try pipe("developPost")
        guard let ub = device.makeBuffer(length: MemoryLayout<FrameParams>.stride,
                                         options: .storageModeShared) else {
            throw VideoError.metalInit("无法创建 uniform buffer")
        }
        self.uniformBuffer = ub
    }

    // MARK: - LUT 上传

    /// 把四段 LUT 打包成 RGBA16Float 3D 纹理（width=b, height=g, depth=r）。
    func installLUT(_ payload: VideoLUTPayload) {
        lock.lock()
        defer { lock.unlock() }
        let tables = [payload.packed(payload.t1), payload.packed(payload.t2),
                      payload.packed(payload.t3), payload.packed(payload.t4)]
        let n = payload.resolution
        var textures: [MTLTexture] = []
        for table in tables {
            let desc = MTLTextureDescriptor()
            desc.textureType = .type3D
            desc.width = n
            desc.height = n
            desc.depth = n
            desc.pixelFormat = .rgba32Float
            desc.usage = [.shaderRead]
            guard let tex = device.makeTexture(descriptor: desc) else { continue }
            let origin = MTLOrigin(x: 0, y: 0, z: 0)
            let size = MTLSize(width: n, height: n, depth: n)
            let region = MTLRegion(origin: origin, size: size)
            let bytes = [UInt8](table.data)
            let rowBytes = n * 4 * MemoryLayout<Float>.size
            let imageBytes = n * n * 4 * MemoryLayout<Float>.size
            tex.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: bytes,
                        bytesPerRow: rowBytes, bytesPerImage: imageBytes)
            textures.append(tex)
        }
        self.lutTextures = textures.count == 4 ? textures : nil
        self.lutSize = n
    }

    var hasLUT: Bool { lock.lock(); defer { lock.unlock() }; return lutTextures != nil }

    /// 取中间纹理池：尺寸一致且（如需物理链）物理纹理已建时直接复用，否则重建。
    /// 调用方必须持有 renderLock。
    private func scratchTextures(width: Int, height: Int, needPhysical: Bool) -> ScratchTextures {
        if let s = scratch, s.width == width, s.height == height,
           (!needPhysical || s.hasPhysical) {
            return s
        }
        func make(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: d)!
        }
        let bw = max(1, width / 2), bh = max(1, height / 2)
        let s = ScratchTextures(
            width: width, height: height,
            linear: make(.rgba32Float, width, height),
            bloomA: make(.rgba32Float, bw, bh),
            bloomB: make(.rgba32Float, bw, bh),
            bloomC: make(.rgba32Float, bw, bh),
            density: needPhysical ? make(.rgba16Float, width, height) : nil,
            grainA: needPhysical ? make(.rgba16Float, width, height) : nil,
            grainB: needPhysical ? make(.rgba16Float, width, height) : nil)
        scratch = s
        return s
    }

    // MARK: - 单帧渲染

    /// - Parameters:
    ///   - source: 解码得到的 BGRA CVPixelBuffer
    ///   - destination: 编码用的 BGRA CVPixelBuffer
    ///   - uniforms: 帧级参数（EV、颗粒、光晕、USM）
    ///   - payload: LUT（提供 span/wire 与 buffer 偏移）
    func render(source: CVPixelBuffer, destination: CVPixelBuffer,
                uniforms: VideoFrameUniforms, payload: VideoLUTPayload) throws {
        // 串行化：uniformBuffer 与 scratch 复用池是单例可变状态，
        // 预览与导出可能并发调用；整帧锁住，commandBuffer 本就同步等待，无吞吐损失。
        renderLock.lock()
        defer { renderLock.unlock() }

        guard let luts = lutTextures else { throw VideoError.lutNotInstalled }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { throw VideoError.badFrame }

        // 输入纹理：BGRA8 → shader 里读 .bgr 得到 RGB display，再转线性 ProPhoto。
        let srcTex = try metalTexture(from: source, pixelFormat: .bgra8Unorm,
                                      width: width, height: height, plane: 0)
        let dstTex = try metalTexture(from: destination, pixelFormat: .bgra8Unorm,
                                      width: width, height: height, plane: 0)

        let pool = scratchTextures(width: width, height: height,
                                   needPhysical: uniforms.grainMode == 1)
        let linearA = pool.linear
        let bloomA = pool.bloomA, bloomB = pool.bloomB, bloomC = pool.bloomC
        let bw = max(1, width / 2), bh = max(1, height / 2)

        let rec709ToPP = VideoColorIO.rec709ToProPhoto
        var params = FrameParams()
        params.lutSize = UInt32(lutSize)
        // t1 shaper 的跨度是固定的 (shaperHighEV - shaperLowEV)=14，
        // 与 wire1 的归一化 span 无关（后者只用于曝光偏移）。
        params.invSpan1 = Float(1.0 / (PreviewLUTService.shaperHighEV - PreviewLUTService.shaperLowEV))
        params.encodedInput = payload.encodedInput ? 1 : 0
        params.autoEV = uniforms.autoEV
        params.cameraOffset = Float(payload.cameraOffset(exposureEV: Double(uniforms.cameraEV)))
        params.printOffset = uniforms.printOffset
        params.grainSigma = uniforms.grainSigma
        params.frameSeed = uniforms.frameSeed
        params.grainR = uniforms.grainAmplitude.x
        params.grainG = uniforms.grainAmplitude.y
        params.grainB = uniforms.grainAmplitude.z
        params.densMinR = uniforms.grainDensityMin.x
        params.densMinG = uniforms.grainDensityMin.y
        params.densMinB = uniforms.grainDensityMin.z
        params.halation = uniforms.halationStrength
        params.diffusion = uniforms.diffusionStrength
        params.usm = uniforms.usmStrength
        params.m0 = SIMD4<Float>(rec709ToPP.columns.0, 0)
        params.m1 = SIMD4<Float>(rec709ToPP.columns.1, 0)
        params.m2 = SIMD4<Float>(rec709ToPP.columns.2, 0)
        params.tint = SIMD4<Float>(uniforms.halationTint, 0)
        params.width = UInt32(width)
        params.height = UInt32(height)
        params.developStrength = uniforms.developStrength
        params.dynamicRange = uniforms.dynamicRange
        params.gradeShadows = uniforms.gradeShadows
        params.gradeHighlights = uniforms.gradeHighlights
        params.gradeBlacks = uniforms.gradeBlacks
        params.gradeWhites = uniforms.gradeWhites
        params.gradeContrast = uniforms.gradeContrast
        params.gradeSaturation = uniforms.gradeSaturation
        params.grainPixelScale = uniforms.grainPixelScale
        params.gradeTemperature = uniforms.gradeTemperature
        params.grainMode = uniforms.grainMode
        params.particleN0 = uniforms.particleN.x
        params.particleN1 = uniforms.particleN.y
        params.particleN2 = uniforms.particleN.z
        params.particleDMax = uniforms.particleDMax
        params.particleBlurPx = uniforms.particleBlurPx
        params.particleMicroPx = uniforms.particleMicroPx
        params.unifR = uniforms.grainUniformity.x
        params.unifG = uniforms.grainUniformity.y
        params.unifB = uniforms.grainUniformity.z
        uniformBuffer.contents().copyMemory(from: &params,
                                            byteCount: MemoryLayout<FrameParams>.stride)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VideoError.metalInit("无法创建 command encoder")
        }
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        // pass 0: 输入 BGRA(display Rec.709) → 线性 ProPhoto → develop → 线性 sRGB
        // 输入转换用一个轻量 kernel 合并进 develop 前：这里先做 CPU 侧不可接受，
        // 故用 develop kernel 直接吃 BGRA 并在 kernel 内做显示→线性转换。
        if uniforms.grainMode == 1 {
            // 物理颗粒链：developPre(CMY 密度) → grainSample(粒子) → blurH/V → developPost
            // 三张中间纹理来自复用池（rgba16Float），不再每帧分配。
            guard let densityTex = pool.density, let grainA = pool.grainA, let grainB = pool.grainB else {
                throw VideoError.metalInit("物理颗粒纹理池未就绪")
            }

            // pre：到 t2 密度
            encoder.setComputePipelineState(pipelineDevelopPre)
            encoder.setTexture(srcTex, index: 0)
            encoder.setTexture(densityTex, index: 1)
            encoder.setTexture(luts[0], index: 2)
            encoder.setTexture(luts[1], index: 3)
            dispatch(encoder, pipeline: pipelineDevelopPre, width: width, height: height)

            // 粒子抽样（只在颗粒开启时，否则写零值仍无害）
            encoder.setComputePipelineState(pipelineGrainSample)
            encoder.setTexture(densityTex, index: 0)
            encoder.setTexture(grainA, index: 1)
            dispatch(encoder, pipeline: pipelineGrainSample, width: width, height: height)

            // 分离高斯：dye-cloud + final blur
            encoder.setComputePipelineState(pipelineGrainBlurH)
            encoder.setTexture(grainA, index: 0)
            encoder.setTexture(grainB, index: 1)
            dispatch(encoder, pipeline: pipelineGrainBlurH, width: width, height: height)
            encoder.setComputePipelineState(pipelineGrainBlurV)
            encoder.setTexture(grainB, index: 0)
            encoder.setTexture(grainA, index: 1)
            dispatch(encoder, pipeline: pipelineGrainBlurV, width: width, height: height)

            // post：密度+颗粒 → t3/t4 → 线性 sRGB
            encoder.setComputePipelineState(pipelineDevelopPost)
            encoder.setTexture(densityTex, index: 0)
            encoder.setTexture(grainA, index: 1)
            encoder.setTexture(linearA, index: 2)
            encoder.setTexture(luts[2], index: 3)
            encoder.setTexture(luts[3], index: 4)
            dispatch(encoder, pipeline: pipelineDevelopPost, width: width, height: height)
        } else {
            encoder.setComputePipelineState(pipelineDevelop)
            encoder.setTexture(srcTex, index: 0)
            encoder.setTexture(linearA, index: 1)
            for (i, tex) in luts.enumerated() { encoder.setTexture(tex, index: 2 + i) }
            dispatch(encoder, pipeline: pipelineDevelop, width: width, height: height)
        }

        // pass 1..3：半分辨率 bloom（提取 → 横 → 纵）
        var bloomParams = params
        bloomParams.width = UInt32(bw)
        bloomParams.height = UInt32(bh)
        uniformBuffer.contents().copyMemory(from: &bloomParams,
                                            byteCount: MemoryLayout<FrameParams>.stride)
        encoder.setComputePipelineState(pipelineBloomDown)
        encoder.setTexture(linearA, index: 0)
        encoder.setTexture(bloomA, index: 1)
        dispatch(encoder, pipeline: pipelineBloomDown, width: bw, height: bh)

        encoder.setComputePipelineState(pipelineBloomH)
        encoder.setTexture(bloomA, index: 0)
        encoder.setTexture(bloomB, index: 1)
        dispatch(encoder, pipeline: pipelineBloomH, width: bw, height: bh)

        encoder.setComputePipelineState(pipelineBloomV)
        encoder.setTexture(bloomB, index: 0)
        encoder.setTexture(bloomC, index: 1)
        dispatch(encoder, pipeline: pipelineBloomV, width: bw, height: bh)

        // pass 4：合成 + OETF → BGRA 输出
        uniformBuffer.contents().copyMemory(from: &params,
                                            byteCount: MemoryLayout<FrameParams>.stride)
        encoder.setComputePipelineState(pipelineComposite)
        encoder.setTexture(linearA, index: 0)
        encoder.setTexture(bloomC, index: 1)
        encoder.setTexture(dstTex, index: 2)
        encoder.setTexture(srcTex, index: 3)
        dispatch(encoder, pipeline: pipelineComposite, width: width, height: height)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw VideoError.metalInit(error.localizedDescription) }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                          width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threads = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }

    private func metalTexture(from buffer: CVPixelBuffer, pixelFormat: MTLPixelFormat,
                              width: Int, height: Int, plane: Int) throws -> MTLTexture {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, pixelFormat,
            width, height, plane, &texture)
        guard status == kCVReturnSuccess, let cvTexture = texture,
              let tex = CVMetalTextureGetTexture(cvTexture) else {
            NSLog("VMetal texture failed status=%d fmt=%d %dx%d plane=%d surface=%d",
                  status, CVPixelBufferGetPixelFormatType(buffer), width, height, plane,
                  CVPixelBufferGetIOSurface(buffer) != nil ? 1 : 0)
            throw VideoError.metalInit("无法从 CVPixelBuffer 创建 Metal 纹理")
        }
        return tex
    }
}

enum VideoError: LocalizedError {
    case noMetalDevice
    case metalInit(String)
    case lutNotInstalled
    case badFrame
    case unsupported
    case cancelled
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "此设备不支持 Metal"
        case .metalInit(let s): return "Metal 初始化失败：\(s)"
        case .lutNotInstalled: return "LUT 尚未烘焙"
        case .badFrame: return "无效的视频帧"
        case .unsupported: return "当前格式不受支持（v1 仅支持 SDR Rec.709 负片）"
        case .cancelled: return "已取消"
        case .exportFailed(let s): return "导出失败：\(s)"
        }
    }
}
