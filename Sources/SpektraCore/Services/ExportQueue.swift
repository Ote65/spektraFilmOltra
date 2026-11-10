import Foundation

struct ExportRequest {
    var id: String = UUID().uuidString
    var photoID: String
    var destination: URL
    var bitDepth: Int = 16
    var colorSpace: String?
    var cctfEncoding: Bool?
    /// 0 表示保持原尺寸；大于 0 且原图更大时按长边降采样。
    var longEdge: Int = 0
}

struct ExportJobState {
    var id: String
    var photoID: String
    var progress: Double
    var message: String
    var isFinished: Bool
    var error: String?
}

/// 导出队列：串行执行全尺寸渲染 + 保存；支持取消与进度回调。
/// 回调在队列内部线程触发，UI 侧需自行切回主线程。
final class ExportQueue {
    private let queue = DispatchQueue(label: "spektra.export", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled: Set<String> = []
    var onUpdate: ((ExportJobState) -> Void)?

    func enqueue(_ request: ExportRequest, photo: LibraryPhoto) {
        queue.async { [weak self] in
            guard let self else { return }
            self.publish(ExportJobState(
                id: request.id, photoID: request.photoID,
                progress: 0, message: "准备中", isFinished: false, error: nil
            ))
            do {
                if self.isCancelled(request.id) {
                    self.publish(ExportJobState(
                        id: request.id, photoID: request.photoID,
                        progress: 0, message: "已取消", isFinished: true, error: "cancelled"
                    ))
                    return
                }
                let original = URL(fileURLWithPath: photo.originalPath)
                var params = try photo.makeParams()
                let loaded = try ImageLoader.load(url: original)
                params.io.inputColorSpace = loaded.colorSpace
                params.io.inputCCTFDecoding = loaded.cctfDecoding
                let colorSpace = request.colorSpace ?? params.io.outputColorSpace
                let cctf = request.cctfEncoding ?? params.io.outputCCTFEncoding
                params.io.outputColorSpace = colorSpace
                params.io.outputCCTFEncoding = cctf
                let pipeline = SimulationPipeline(params: params, keepTaps: false)
                pipeline.shouldCancel = { self.isCancelled(request.id) }
                let result = pipeline.process(loaded.image, progress: { label, step, total in
                    self.publish(ExportJobState(
                        id: request.id, photoID: request.photoID,
                        progress: Double(step) / Double(total),
                        message: label, isFinished: false, error: nil
                    ))
                })
                if self.isCancelled(request.id) {
                    self.publish(ExportJobState(
                        id: request.id, photoID: request.photoID,
                        progress: 1, message: "已取消", isFinished: true, error: "cancelled"
                    ))
                    return
                }
                var output = result.rgbOut
                if request.longEdge > 0 {
                    output = Resize.longEdge(output, maxSize: request.longEdge)
                }
                self.publish(ExportJobState(
                    id: request.id, photoID: request.photoID,
                    progress: 0.95, message: "写入 \(request.destination.lastPathComponent)",
                    isFinished: false, error: nil
                ))
                try ImageExport.save(output, to: request.destination,
                                     bitDepth: request.bitDepth,
                                     colorSpace: colorSpace, cctfEncoding: cctf)
                self.publish(ExportJobState(
                    id: request.id, photoID: request.photoID,
                    progress: 1, message: "完成", isFinished: true, error: nil
                ))
            } catch {
                self.publish(ExportJobState(
                    id: request.id, photoID: request.photoID,
                    progress: 0, message: "失败", isFinished: true,
                    error: String(describing: error)
                ))
            }
        }
    }

    func cancel(_ id: String) {
        lock.lock()
        cancelled.insert(id)
        lock.unlock()
    }

    private func isCancelled(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(id)
    }

    private func publish(_ state: ExportJobState) {
        onUpdate?(state)
    }
}
