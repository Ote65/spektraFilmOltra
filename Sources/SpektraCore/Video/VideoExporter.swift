import Foundation
import AVFoundation

/// 导出会话：串行队列 + 进度回调 + 取消（方案 2.1、7.4）。
/// 与 ExportQueue（照片）分开；视频独占一条串行队列，避免并发 GPU 争抢。
@MainActor
final class VideoExporter: ObservableObject {
    @Published private(set) var progress = VideoProgress()
    @Published private(set) var isExporting = false

    private let pipeline: VideoFramePipeline
    private let queue = DispatchQueue(label: "spektrafilm.video.exporter", qos: .userInitiated)
    private var cancelFlag = false
    private var currentTask: Task<Void, Never>?

    init(renderer: VideoRendering) {
        self.pipeline = VideoFramePipeline(renderer: renderer)
    }

    var canCancel: Bool { isExporting }

    func cancel() {
        guard isExporting else { return }
        cancelFlag = true
        progress = VideoProgress(stage: .cancelled, message: "正在停止…")
    }

    /// 成片导出。UI 负责把 source 准备好（沙盒路径）。
    func export(
        project: VideoProject,
        source: URL,
        destination: URL,
        autoEV: Double,
        longEdge: Int
    ) async throws {
        cancelFlag = false
        isExporting = true
        progress = VideoProgress(stage: .baking, message: "烘焙 LUT")
        defer {
            isExporting = false
            currentTask = nil
        }

        let setup: VideoFramePipeline.RenderSetup
        do {
            setup = try pipeline.prepareSetup(
                edit: project.edit, autoEV: autoEV,
                longEdge: longEdge, clipID: project.id)
        } catch {
            progress = VideoProgress(stage: .failed, message: error.localizedDescription)
            throw error
        }

        progress = VideoProgress(stage: .rendering, frameCount: Int(project.duration * project.fps))
        let expectedFrames = max(1, Int((project.duration * project.fps).rounded()))
        // 先导出无声视频，再 mux 音轨。避免 AVAssetWriter 双 input 背压死锁。
        let silentURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).silent.mov")
        defer { try? FileManager.default.removeItem(at: silentURL) }
        do {
            try await pipeline.export(
                source: source,
                destination: silentURL,
                setup: setup,
                codec: project.exportSettings.codec,
                audioPassthrough: false, // 音轨交由 VideoAudioMuxer 后处理
                totalFrames: expectedFrames,
                progress: { [weak self] index, total in
                    guard let self else { return }
                    Task { @MainActor in
                        self.progress = VideoProgress(
                            stage: .rendering, frameIndex: index, frameCount: total,
                            message: "显影 \(index) 帧")
                    }
                },
                shouldCancel: { [weak self] in self?.cancelFlag ?? false }
            )
            // 音频直通合成（若源有音轨且用户开启）。
            if project.exportSettings.audioPassthrough {
                progress = VideoProgress(stage: .writing, message: "合成音轨")
                let muxed = try await VideoAudioMuxer.mux(
                    videoOnly: silentURL, source: source, destination: destination)
                if !muxed {
                    try FileManager.default.copyItem(at: silentURL, to: destination)
                }
            } else {
                try FileManager.default.moveItem(at: silentURL, to: destination)
            }
        } catch is CancellationError {
            progress = VideoProgress(stage: .cancelled, message: "已取消，临时文件已清理")
            try? FileManager.default.removeItem(at: destination)
            throw VideoError.cancelled
        } catch {
            if cancelFlag {
                progress = VideoProgress(stage: .cancelled, message: "已取消")
                try? FileManager.default.removeItem(at: destination)
                throw VideoError.cancelled
            }
            progress = VideoProgress(stage: .failed, message: error.localizedDescription)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        progress = VideoProgress(stage: .finished, message: "导出完成")
    }

    /// 代理片：从参考时间附近截 3–5 秒，低分辨率由 Writer 码率控制（v1 保持源分辨率以保实现简单）。
    func makeProxy(
        project: VideoProject,
        source: URL,
        destination: URL,
        autoEV: Double
    ) async throws {
        cancelFlag = false
        let seconds = min(project.exportSettings.proxySeconds, max(1, project.duration))
        let start = max(0, min(project.referenceTime - seconds / 2, project.duration - seconds))
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let setup = try pipeline.prepareSetup(
            edit: project.edit, autoEV: autoEV,
            longEdge: Int(project.pixelWidth), clipID: project.id + "-proxy")

        try await pipeline.export(
            source: source, destination: destination, setup: setup,
            codec: .hevcStandard, audioPassthrough: false, timeRange: range,
            maxFrames: Int(seconds * Double(project.exportSettings.proxyFPS)),
            progress: { _, _ in },
            shouldCancel: { [weak self] in self?.cancelFlag ?? false })
    }
}
