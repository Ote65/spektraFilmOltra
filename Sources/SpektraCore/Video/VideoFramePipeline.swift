import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import ImageIO
import CoreGraphics
import CoreImage

/// 视频探测 / 参考帧测光 / 帧渲染循环（方案 6.1、7.3、7.4）。
///
/// 全程 AVAssetReader/Writer 硬解硬编；逐帧 CVPixelBuffer 经 Metal 零拷贝渲染。
/// 帧泵在串行 queue 上跑，进度通过闭包回主线程。
final class VideoFramePipeline: @unchecked Sendable {
    private let renderer: VideoRendering
    private let baker = VideoLUTBaker()

    init(renderer: VideoRendering) {
        self.renderer = renderer
    }

    // MARK: - 探测

    struct VideoInfo {
        var duration: Double = 0
        var fps: Double = 24
        var width: Int = 0
        var height: Int = 0
        var hasAudio: Bool = false
        var isHDR: Bool = false
    }

    func probe(url: URL) async throws -> VideoInfo {
        try Task.checkCancellation()
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.unsupported
        }
        let size = try await track.load(.naturalSize)
        let rate = try await track.load(.nominalFrameRate)
        let transform = try await track.load(.preferredTransform)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let angle = atan2(Double(transform.b), Double(transform.a)) * 180 / .pi
        let rotated = abs(abs(angle) - 90) < 1 || abs(abs(angle) - 270) < 1
        return VideoInfo(
            duration: CMTimeGetSeconds(duration),
            fps: rate > 0 ? Double(rate) : 24,
            width: rotated ? Int(size.height) : Int(size.width),
            height: rotated ? Int(size.width) : Int(size.height),
            hasAudio: hasAudio,
            isHDR: false // v1 只接受 SDR Rec.709；HDR 门禁留待 M6 后扩展。
        )
    }

    // MARK: - 参考帧抽帧与测光

    /// 在时间 t 抽一帧，返回显示编码 CGImage（已应用旋转，长边受 `maximumSize` 约束）。
    func referenceFrame(url: URL, at time: Double,
                        maximumSize: CGSize = CGSize(width: 256, height: 256)) async throws -> CGImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let t = CMTime(value: Int64(max(0, time) * 600), timescale: 600)
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { _, image, _, result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if result == .succeeded, let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 与照片用同一 AutoExposure：输入线性 ProPhoto，色彩空间一致。
    func measureEV(cgImage: CGImage, method: String) -> Double {
        guard let image = imageRGB(from: cgImage) else { return 0 }
        return PreviewLUTService.measureAutoEV(
            source: image, colorSpace: "ProPhoto RGB",
            applyCCTFDecoding: false, method: method)
    }

    private func imageRGB(from cgImage: CGImage) -> ImageRGB? {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var image = ImageRGB(width: w, height: h)
        for i in 0..<(w * h) {
            let display = Vec3(Double(pixels[i*4]) / 255.0,
                               Double(pixels[i*4+1]) / 255.0,
                               Double(pixels[i*4+2]) / 255.0)
            let linear = VideoColorIO.displayRGBToLinearProPhoto(display)
            image.data[i*3] = Float(linear.x)
            image.data[i*3+1] = Float(linear.y)
            image.data[i*3+2] = Float(linear.z)
        }
        return image
    }

    // MARK: - 一次性渲染设置

    struct RenderSetup {
        let payload: VideoLUTPayload
        let compRatio: Double
        let autoEV: Double
        let edit: PhotoEdit
        let clipSeed: UInt32
        let longEdge: Int
    }

    func prepareSetup(edit: PhotoEdit, autoEV: Double, longEdge: Int,
                      clipID: String) throws -> RenderSetup {
        guard let payload = baker.bake(edit: edit) else { throw VideoError.unsupported }
        let comp = baker.compRatio(edit: edit, payload: payload)
        return RenderSetup(payload: payload, compRatio: comp, autoEV: autoEV,
                           edit: edit, clipSeed: VideoGrainModel.clipSeed(for: clipID),
                           longEdge: longEdge)
    }

    /// 影调轴的默认值：显影 100%，宽容度 45%（抵消视频"二次上曲线"造成的高对比）。
    static let defaultDevelopStrength = 100.0
    static let defaultDynamicRange = 45.0

    func frameUniforms(setup: RenderSetup, frameIndex: Int,
                       longEdgeOverride: Int? = nil,
                       edit override: PhotoEdit? = nil) -> VideoFrameUniforms {
        let e = override ?? setup.edit
        let grain = VideoGrainModel.fit(edit: e,
                                        longEdgePixels: longEdgeOverride ?? setup.longEdge,
                                        clipSeed: setup.clipSeed)
        let hal = e.filmRender.halation
        let diff = e.camera.diffusionFilter
        // unsharpMask 是 [半径, 强度]：强度在第二格，读第一格会让清晰度轴永远无效。
        let usm = e.scanner.unsharpMask.count > 1 ? e.scanner.unsharpMask[1] : 0
        var u = VideoFrameUniforms()
        u.autoEV = Float(setup.autoEV)
        u.cameraEV = Float(e.camera.exposureCompensationEV)
        u.printOffset = Float(setup.payload.printOffset(
            printExposure: e.enlarger.printExposure,
            compRatio: setup.compRatio,
            compensate: e.enlarger.printExposureCompensation))
        u.grainEnabled = grain.enabled
        u.grainAmplitude = grain.amplitude
        u.grainSigma = grain.sigma
        u.grainDensityMin = grain.densityMin
        // 预览按 1/2、1/4 抽帧时，高频颗粒要按同一比例补偿，屏幕观感才与成片一致。
        let renderEdge = longEdgeOverride ?? setup.longEdge
        let pixelScale = Float(renderEdge) / Float(max(setup.longEdge, 1))
        u.grainPixelScale = min(max(pixelScale, 0.25), 1)
        u.frameSeed = grain.seed ^ (UInt32(truncatingIfNeeded: frameIndex) &* 0x9E3779B1)
        u.halationStrength = Float(min(max(hal.halationAmount, 0), 1)) * 0.25 * (hal.active ? 1 : 0)
        u.diffusionStrength = Float(min(max(diff.strength, 0), 1)) * 0.15 * (diff.active ? 1 : 0)
        u.usmStrength = Float(min(max(usm, 0), 1)) * 0.35
        u.halationTint = SIMD3<Float>(1.0, 0.6 + Float(diff.haloWarmth) * 0.2, 0.35)

        // 显影 / 影调轴：全部落在 uniform 上，不参与 LUT 烘焙，拖动滑条即时应答。
        let q = e.quickIntents
        let develop = q["develop_strength"] ?? Self.defaultDevelopStrength
        let dyn = q["dynamic_range"] ?? Self.defaultDynamicRange
        u.developStrength = Float(min(max(develop, 0), 100) / 100)
        u.dynamicRange = Float(min(max(dyn, 0), 100) / 100)
        u.gradeShadows = Float(min(max(q["grade_shadows"] ?? 0, -100), 100) / 100)
        // 高光柔和走「压高光」：负值把亮部收进肩部，不会像提亮那样把高光推爆。
        let highlights = (q["grade_highlights"] ?? 0) - (q["highlight_softening"] ?? 0)
        u.gradeHighlights = Float(min(max(highlights, -100), 100) / 100)
        u.gradeBlacks = Float(min(max(q["grade_blacks"] ?? 0, -100), 100) / 100)
        u.gradeWhites = Float(min(max(q["grade_whites"] ?? 0, -100), 100) / 100)
        // 画面对比度：与调色台的 grade_contrast 同轴叠加。
        let contrast = (q["grade_contrast"] ?? 0) + (q["tonal_contrast"] ?? 0)
        u.gradeContrast = Float(min(max(contrast, -100), 100) / 100)
        // 色彩浓度：染料层间抑制在视频里用保真饱和度承载（LUT 不含该字段）。
        let saturation = 1 + ((q["grade_saturation"] ?? 0) + (q["color_density"] ?? 0)) / 100
        u.gradeSaturation = Float(min(max(saturation, 0), 2))
        // 印相冷暖：相纸滤色偏移在 LUT 里被归零，改由显示域 R/B 增益承载。
        u.gradeTemperature = Float(min(max(q["temperature"] ?? 0, -100), 100) / 100)
        return u
    }

    // MARK: - 单帧显影（仅暂停时调用，播放中不跑，避免算力消耗）

    /// 对指定时间点的单帧做显影，返回 CGImage。
    /// UI 只在播放器暂停/seek 停下后调用；播放中不调用，故不会逐帧吃 GPU。
    /// `maxEdge` 控制预览抽帧的长边（完整 / 1/2 / 1/4）；传 nil 用源尺寸长边。
    /// `edit` 传入当前参数：显影/影调轴只改 uniform，不必重烘 LUT。
    func developStill(url: URL, at time: Double, setup: RenderSetup,
                      frameIndex: Int, maxEdge: Int? = nil,
                      edit: PhotoEdit? = nil) async throws -> CGImage? {
        let pair = try await developStillPair(url: url, at: time, setup: setup,
                                             frameIndex: frameIndex, maxEdge: maxEdge, edit: edit)
        return pair?.developed
    }

    /// 同一次解码同时给出「原片帧」和「显影帧」。
    /// 预览暂停时把原片帧垫在下面、显影帧在上面渐显，两张图逐像素同源，
    /// 不会出现相邻帧叠影（那会被看成"割裂"）。
    func developStillPair(url: URL, at time: Double, setup: RenderSetup,
                          frameIndex: Int, maxEdge: Int? = nil,
                          edit: PhotoEdit? = nil) async throws -> (base: CGImage, developed: CGImage)? {
        let size: CGSize
        if let maxEdge, maxEdge > 0 {
            size = CGSize(width: maxEdge, height: maxEdge)
        } else {
            size = CGSize(width: setup.longEdge, height: setup.longEdge)
        }
        guard let source = try await referenceFrame(url: url, at: time, maximumSize: size) else { return nil }
        return try renderPair(source: source, setup: setup, frameIndex: frameIndex, edit: edit)
    }

    /// 用播放器**当前正在显示**的那一帧（像素缓冲）出「原片帧 + 显影帧」。
    /// 两块图来自同一块像素，暂停渐显时不可能混入任何相邻帧。
    func developStillPair(pixelBuffer: CVPixelBuffer, setup: RenderSetup,
                          frameIndex: Int, maxEdge: Int? = nil,
                          edit: PhotoEdit? = nil) throws -> (base: CGImage, developed: CGImage)? {
        guard var source = StillBridge.cgImage(from: pixelBuffer) else { return nil }
        if let maxEdge, maxEdge > 0, max(source.width, source.height) > maxEdge,
           let scaled = StillBridge.scaled(source, longEdge: maxEdge) {
            source = scaled
        }
        return try renderPair(source: source, setup: setup, frameIndex: frameIndex, edit: edit)
    }

    /// 只取原片帧（暂停瞬间先冻屏用）：一次像素拷贝 + 可选缩放，不进 GPU。
    func baseImage(pixelBuffer: CVPixelBuffer, maxEdge: Int? = nil) -> CGImage? {
        guard let source = StillBridge.cgImage(from: pixelBuffer) else { return nil }
        if let maxEdge, maxEdge > 0, max(source.width, source.height) > maxEdge {
            return StillBridge.scaled(source, longEdge: maxEdge) ?? source
        }
        return source
    }

    /// 同一张 CGImage 进 Metal：原样返回它当底座，渲染结果当显影帧。
    private func renderPair(source: CGImage, setup: RenderSetup,
                            frameIndex: Int, edit: PhotoEdit?) throws -> (base: CGImage, developed: CGImage)? {
        let w = source.width, h = source.height
        guard w > 0, h > 0 else { return nil }

        guard let srcPB = StillBridge.pixelBuffer(width: w, height: h),
              let dstPB = StillBridge.pixelBuffer(width: w, height: h) else {
            throw VideoError.exportFailed("无法分配单帧缓冲")
        }
        guard StillBridge.draw(source, into: srcPB) else { return nil }

        renderer.installLUT(setup.payload)
        // 颗粒尺度跟随实际渲染像素，放大到屏幕后与成片观感一致。
        let uniforms = frameUniforms(setup: setup, frameIndex: frameIndex,
                                     longEdgeOverride: max(w, h), edit: edit)
        try renderer.render(source: srcPB, destination: dstPB,
                            uniforms: uniforms, payload: setup.payload)
        guard let developed = StillBridge.cgImage(from: dstPB) else { return nil }
        return (source, developed)
    }

    // MARK: - 成片 / 代理片导出

    /// AVAssetReader(BGRA) → Metal → AVAssetWriter。视频泵串行消耗帧，
    /// 音频泵直通；两路都 markAsFinished 后 finishWriting。
    @discardableResult
    func export(
        source: URL,
        destination: URL,
        setup: RenderSetup,
        codec: VideoCodec,
        audioPassthrough: Bool,
        timeRange: CMTimeRange? = nil,
        maxFrames: Int? = nil,
        totalFrames: Int? = nil,
        progress: @escaping (Int, Int) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> Int {
        try Task.checkCancellation()
        let asset = AVAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.unsupported
        }
        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        // 帧缓冲、Metal 渲染全程使用「传感器方向」尺寸（=naturalSize），与横拍素材一致，
        // 避开 AVAssetReaderVideoCompositionOutput 对 10-bit HEVC Rext 合成出黑帧的坑。
        let frameWidth = Int(natural.width)
        let frameHeight = Int(natural.height)

        // 竖拍旋转必须「烘焙进像素」，不能只写 transform 元数据：
        // 只写元数据时 App 内播放器会读它自动转正，但保存到系统相册后元数据丢失
        // → 画面横躺（2026-11-18 用户实证）。这里渲染后按显示方向真实旋转像素，
        // 输出 track 不写 transform，任何播放器/相册看到的都是正立画面。
        let angle = atan2(Double(transform.b), Double(transform.a)) * 180 / .pi
        let rotated = abs(abs(angle) - 90) < 1 || abs(abs(angle) - 270) < 1
        let outWidth = rotated ? frameHeight : frameWidth
        let outHeight = rotated ? frameWidth : frameHeight
        // preferredTransform 的旋转方向 → CoreImage 方向枚举。
        // [0,1,-1,0]（b>0,c<0，逆时针90）实测对应 .right（顺时针90）后画面正立，
        // [0,-1,1,0]（b<0,c>0）对应 .left。其余 180° 用 .down，identity 不旋转。
        let orientation: CGImagePropertyOrientation? = {
            if !rotated { return nil }
            if abs(abs(angle) - 180) < 1 { return .down }
            return transform.b > 0 ? .right : .left
        }()
        let rotateContext = orientation == nil ? nil : CIContext()

        let reader = try AVAssetReader(asset: asset)
        // 解码帧直接进 Metal 纹素：必须显式声明 Metal 兼容。iOS 上解码器默认给的是
        // 普通内存缓冲，少了这个键 CVMetalTextureCacheCreateTextureFromImage 会直接失败
        // （macOS 的 VideoToolbox 恰好总走 IOSurface，所以这个坑只在 iOS 暴露）。
        let readSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        // 一律用 AVAssetReaderTrackOutput 直接解码，不再走 AVAssetReaderVideoCompositionOutput。
        // 后者依赖 CPU 视频合成器，对 10-bit HEVC Rext（yuv422p10le，如 A001_C257）旋转
        // 合成时会产出全黑/斜纹垃圾帧（2026-11-18 实证：直解亮度 110，合成后为 0）。
        // 直接解码出的帧是传感器方向，经 Metal 渲染后仍按传感器方向编码，旋转交给
        // writer 的 transform 元数据完成 —— 完全绕开合成器的编码兼容性问题。
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readSettings)
        trackOutput.alwaysCopiesSampleData = false
        let output: AVAssetReaderOutput = trackOutput
        guard reader.canAdd(output) else { throw VideoError.exportFailed("无法添加视频读取器") }
        reader.add(output)
        if let range = timeRange { reader.timeRange = range }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        // 输出尺寸用显示方向：像素在帧泵里已真实旋转到该方向，故不设 transform 元数据。
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(codec: codec, width: outWidth, height: outHeight, fps: 24))
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoError.exportFailed("无法添加视频写入器") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if audioPassthrough,
           let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let aout = try? AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil),
           reader.canAdd(aout) {
            reader.add(aout)
            let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            ain.expectsMediaDataInRealTime = false
            if writer.canAdd(ain) {
                writer.add(ain)
                audioInput = ain
                audioOutput = aout
            }
        }

        renderer.installLUT(setup.payload)
        guard reader.startReading() else {
            throw VideoError.exportFailed(reader.error?.localizedDescription ?? "读取器无法启动")
        }
        guard writer.startWriting() else {
            throw VideoError.exportFailed(writer.error?.localizedDescription ?? "写入器无法启动")
        }
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

        // 引用类型的状态机，避免 escaping 闭包捕获可变局部变量。
        let state = ExportState(writer: writer, audioRequired: audioInput != nil)
        // 进度总数只用于显示：maxFrames 是截断上限，totalFrames 是时长推算的期望帧数，
        // 两者都不给时进度条无法前进（UI 会显示 n/0）。
        let totalHint = totalFrames ?? maxFrames ?? 0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.onFinish = { result in
                switch result {
                case .success: continuation.resume(returning: ())
                case .failure(let e): continuation.resume(throwing: e)
                }
            }

            let videoQueue = DispatchQueue(label: "spektrafilm.video.frames.\(UUID().uuidString)", qos: .userInitiated)
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if shouldCancel() {
                        videoInput.markAsFinished()
                        state.finishVideo(error: VideoError.cancelled)
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        videoInput.markAsFinished()
                        state.finishVideo(error: nil)
                        return
                    }
                    defer { CMSampleBufferInvalidate(sample) }
                    guard let src = CMSampleBufferGetImageBuffer(sample) else { continue }
                    guard let dst = PixelBufferPool.make(
                        width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src)) else {
                        videoInput.markAsFinished()
                        state.finishVideo(error: VideoError.exportFailed("无法分配输出像素缓冲"))
                        return
                    }
                    let index = state.nextIndex()
                    let uniforms = self.frameUniforms(setup: setup, frameIndex: index)
                    do {
                        try self.renderer.render(source: src, destination: dst,
                                                 uniforms: uniforms, payload: setup.payload)
                    } catch {
                        videoInput.markAsFinished()
                        state.finishVideo(error: error)
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let dur = CMSampleBufferGetDuration(sample)

                    // 竖拍：把渲染结果（传感器方向）真实旋转到显示方向的像素，
                    // 再交给编码器。像素本身转正，不依赖 transform 元数据，
                    // 避免存进系统相册后元数据丢失导致横屏。横拍直接走原帧。
                    let encodeBuffer: CVPixelBuffer
                    if let orientation, let rotateContext,
                       let rotatedBuffer = Self.rotatePixelBuffer(
                        dst, orientation: orientation, context: rotateContext,
                        width: outWidth, height: outHeight) {
                        encodeBuffer = rotatedBuffer
                    } else if orientation != nil {
                        // 旋转失败时宁可中止，也不要静默产出横躺成片。
                        videoInput.markAsFinished()
                        state.finishVideo(error: VideoError.exportFailed("旋转输出帧失败"))
                        return
                    } else {
                        encodeBuffer = dst
                    }

                    guard let developed = PixelBufferPool.sampleBuffer(
                        from: encodeBuffer, presentationTime: pts, duration: dur) else {
                        videoInput.markAsFinished()
                        state.finishVideo(error: VideoError.exportFailed("构造输出帧失败"))
                        return
                    }
                    let appended = videoInput.append(developed)
                    guard appended else {
                        videoInput.markAsFinished()
                        state.finishVideo(error: VideoError.exportFailed(
                            writer.error?.localizedDescription ?? "写入帧失败"))
                        return
                    }
                    // 不 invalidate developed：writer 可能还在异步读取其 pixelBuffer，
                    // 手动 invalidate 会让后续帧的编码管线阻塞。交给 ARC 释放。
                    let count = state.advance()
                    progress(count, totalHint)
                    if let maxFrames, count >= maxFrames {
                        videoInput.markAsFinished()
                        state.finishVideo(error: nil)
                        // maxFrames 测试场景：音频泵可能还未读到 EOF，主动收尾音频。
                        if let audioInput { audioInput.markAsFinished(); state.finishAudio() }
                        return
                    }
                }
            }

            // 音频直通泵（独立队列，与视频并行；两路都 finish 后才写封装）。
            if let audioInput, let audioOutput {
                let audioQueue = DispatchQueue(label: "spektrafilm.video.audio.\(UUID().uuidString)", qos: .utility)
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        if shouldCancel() { audioInput.markAsFinished(); state.finishAudio(); return }
                        guard let sample = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            state.finishAudio()
                            return
                        }
                        if !audioInput.append(sample) { audioInput.markAsFinished(); state.finishAudio(); return }
                        CMSampleBufferInvalidate(sample)
                    }
                }
            }
        }
        return state.renderedCount
    }

    /// 用 CoreImage（GPU 加速）把 CVPixelBuffer 按方向旋转到指定显示尺寸，写回新的
    /// CVPixelBuffer。CI 的 oriented 方向经验证无黑边、方向正确；逐像素/纯 Swift
    /// 旋转 688ms/帧太慢，vImage 在本素材的 BGRA 上方向错乱，故选 CoreImage。
    private static func rotatePixelBuffer(_ src: CVPixelBuffer,
                                          orientation: CGImagePropertyOrientation,
                                          context: CIContext,
                                          width: Int, height: Int) -> CVPixelBuffer? {
        let ci = CIImage(cvPixelBuffer: src).oriented(orientation)
        var dst: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &dst)
        guard status == kCVReturnSuccess, let out = dst else { return nil }
        context.render(ci, to: out, bounds: ci.extent, colorSpace: nil)
        return out
    }

    private static func videoSettings(codec: VideoCodec, width: Int, height: Int, fps: Int) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec == .proRes422LT ? AVVideoCodecType.proRes422LT : AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        // 色彩属性对所有编码都必须声明：缺了它 VideoToolbox 写出的片在相册里
        // 会整段黑屏（只有元数据没有图像）。此前只在 ProRes 分支写，HEVC 分支
        // 遗漏，是同类静默坏片的隐患，统一提到公共段。
        settings[AVVideoColorPropertiesKey as String] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        if codec != .proRes422LT {
            // 码率只认 `VideoCodec.bitrateMbps` 一处：导出与「预估体积」共用同一张表，
            // 否则 UI 承诺的数字和实际写出的码率会各走一套。
            let bitrate = Int(codec.bitrateMbps * 1_000_000)
            settings[AVVideoCompressionPropertiesKey as String] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ]
        }
        return settings
    }
}

/// 帧泵状态机：锁保护计数与完成标志，两路输入都完成后只触发一次 finishWriting。
private final class ExportState {
    private let writer: AVAssetWriter
    private let lock = NSLock()
    private var index = 0
    private(set) var renderedCount = 0
    private var videoFinished = false
    private var audioFinished: Bool
    private var terminalError: Error?
    private var finalized = false
    var onFinish: ((Result<Void, Error>) -> Void)?

    init(writer: AVAssetWriter, audioRequired: Bool) {
        self.writer = writer
        self.audioFinished = !audioRequired
    }

    func nextIndex() -> Int { lock.lock(); defer { lock.unlock() }; return index }

    func advance() -> Int {
        lock.lock(); defer { lock.unlock() }
        index += 1
        renderedCount = index
        return index
    }

    func finishVideo(error: Error?) {
        lock.lock()
        videoFinished = true
        if let error, terminalError == nil { terminalError = error }
        let shouldFinalize = videoFinished && audioFinished && !finalized
        if shouldFinalize { finalized = true }
        let err = terminalError
        lock.unlock()
        if shouldFinalize { finalize(error: err) }
    }

    func finishAudio() {
        lock.lock()
        audioFinished = true
        let shouldFinalize = videoFinished && audioFinished && !finalized
        if shouldFinalize { finalized = true }
        let err = terminalError
        lock.unlock()
        if shouldFinalize { finalize(error: err) }
    }

    private func finalize(error: Error?) {
        if let error {
            onFinish?(.failure(error))
            return
        }
        writer.finishWriting { [weak self] in
            guard let self else { return }
            if writer.status == .completed {
                self.onFinish?(.success(()))
            } else {
                self.onFinish?(.failure(VideoError.exportFailed(
                    writer.error?.localizedDescription ?? "封装失败")))
            }
        }
    }
}

/// 每帧分配独立 CVPixelBuffer（AVAssetWriter 会持有，绝不复用）。
private enum PixelBufferPool {
    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            // ProRes 母版走 VideoToolbox 编码，缓冲必须挂在 IOSurface 上；
            // 纯内存 BGRA 在 HEVC 能过，到 ProRes 会写出一段没有图像的黑轨。
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        return status == kCVReturnSuccess ? pixelBuffer : nil
    }

    static func sampleBuffer(from pixelBuffer: CVPixelBuffer,
                             presentationTime: CMTime,
                             duration: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &format) == noErr, let fmt = format else { return nil }
        var sample: CMSampleBuffer?
        // duration 必须是有效值：.invalid 会让 HEVC 编码器在 finishWriting 卡死。
        let validDuration = duration.isValid && duration.seconds > 0
            ? duration : CMTime(value: 1, timescale: 24)
        var timing = CMSampleTimingInfo(duration: validDuration,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

/// 单帧显影用的 CGImage ↔ BGRA CVPixelBuffer 桥接。
/// 只在用户暂停/seek 停下时调用一次，成本可忽略。
private enum StillBridge {
    static func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }

    static func draw(_ image: CGImage, into buffer: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }

    static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let data = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let image = ctx.makeImage() else { return nil }
        return image
    }

    /// 按长边等比缩小（预览档位用）。
    static func scaled(_ image: CGImage, longEdge: Int) -> CGImage? {
        let scale = Double(longEdge) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
