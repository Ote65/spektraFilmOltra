import Foundation
#if os(iOS)
import Photos
#endif

/// 导出落点：把沙盒文件写进系统相册。
enum PhotoLibraryExport {
    enum Outcome {
        case saved
        case denied
        case failed
    }

    static func save(_ url: URL, completion: @escaping (Outcome) -> Void) {
        #if os(iOS)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.denied) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
            } completionHandler: { success, _ in
                DispatchQueue.main.async { completion(success ? .saved : .failed) }
            }
        }
        #else
        completion(.failed)
        #endif
    }
}
