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

    /// App 产出的成片统一归档到这个用户相簿。
    static let albumTitle = "OltraFilm"

    /// - Parameter album: 非 nil 时把成片归档到同名用户相簿（不存在则自动新建）；
    ///   受限相册权限只能新增资源，此时退回普通保存。nil 表示只写入相册（导入原片）。
    static func save(_ url: URL, album: String? = nil, completion: @escaping (Outcome) -> Void) {
        #if os(iOS)
        // 枚举与新建相簿要求完整相册权限；纯写入保持 addOnly。
        let access: PHAccessLevel = (album == nil) ? .addOnly : .readWrite
        PHPhotoLibrary.requestAuthorization(for: access) { status in
            guard status == .authorized || status == .limited else {
                // 用户只给过「仅新增」权限时，退回不归档相簿的普通保存。
                if album != nil {
                    save(url, album: nil, completion: completion)
                } else {
                    DispatchQueue.main.async { completion(.denied) }
                }
                return
            }
            var existingAlbum: PHAssetCollection?
            var newAlbumTitle: String?
            if let album, status == .authorized {
                existingAlbum = findAlbum(named: album)
                if existingAlbum == nil { newAlbumTitle = album }
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                if let existingAlbum {
                    PHAssetCollectionChangeRequest(for: existingAlbum)?
                        .addAssets([placeholder] as NSArray)
                } else if let newAlbumTitle {
                    let created = PHAssetCollectionChangeRequest
                        .creationRequestForAssetCollection(withTitle: newAlbumTitle)
                    created.addAssets([placeholder] as NSArray)
                }
            } completionHandler: { success, _ in
                DispatchQueue.main.async { completion(success ? .saved : .failed) }
            }
        }
        #else
        completion(.failed)
        #endif
    }

    #if os(iOS)
    /// 按标题查找用户相簿；PhotoKit 没有按标题的 fetch，只能枚举。
    private static func findAlbum(named title: String) -> PHAssetCollection? {
        let result = PHAssetCollection.fetchAssetCollections(with: .album,
                                                             subtype: .albumRegular,
                                                             options: nil)
        var match: PHAssetCollection?
        result.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == title {
                match = collection
                stop.pointee = true
            }
        }
        return match
    }
    #endif
}
