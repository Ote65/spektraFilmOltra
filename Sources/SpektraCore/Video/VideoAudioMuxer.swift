import Foundation
import AVFoundation

/// 音频直通合成：把显影后的无声视频与源音轨用 AVMutableComposition 合成。
///
/// 为什么不直接在导出时双写音视频轨：AVAssetWriter 的两路 input 各自
/// requestMediaDataWhenReady 会在背压下互等（视频轨等音频轨 append，
/// 音频轨等 writer ready），导致 finishWriting 永久挂起。分离成
/// "先导出视频 + 后 mux 音轨"可彻底消除该竞态，且音轨零重编码。
enum VideoAudioMuxer {
    /// 把 source 的音轨直通合成到 videoOnly（无声成片），结果写到 destination。
    /// - Returns: 是否成功合入了音轨；源无音轨时返回 false 且不动文件。
    static func mux(videoOnly: URL, source: URL, destination: URL) async throws -> Bool {
        let vAsset = AVAsset(url: videoOnly)
        let sAsset = AVAsset(url: source)

        guard let vTrack = try await vAsset.loadTracks(withMediaType: .video).first else {
            throw VideoError.exportFailed("成片无视频轨")
        }
        guard let aTrack = try await sAsset.loadTracks(withMediaType: .audio).first else {
            return false // 源无音轨：调用方直接使用无声成片。
        }
        let duration = try await vAsset.load(.duration)
        guard duration.seconds > 0 else { return false }

        let composition = AVMutableComposition()
        guard let vComp = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aComp = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.exportFailed("无法创建合成轨")
        }
        try vComp.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                  of: vTrack, at: .zero)
        let audioDuration = try await aTrack.load(.timeRange).duration
        let useDuration = CMTimeMinimum(audioDuration, duration)
        try aComp.insertTimeRange(CMTimeRange(start: .zero, duration: useDuration),
                                  of: aTrack, at: .zero)

        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoError.exportFailed("无法创建合成导出器")
        }
        try? FileManager.default.removeItem(at: destination)
        exporter.outputURL = destination
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { c.resume() }
        }
        guard exporter.status == .completed else {
            throw VideoError.exportFailed(exporter.error?.localizedDescription ?? "音频合成失败")
        }
        return true
    }
}
