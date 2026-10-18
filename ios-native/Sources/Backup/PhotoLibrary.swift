import Foundation
@preconcurrency import Photos
import UniformTypeIdentifiers

struct DeviceAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    let count: Int
    let isShared: Bool
}

struct PreparedPhoto: Codable, Sendable {
    let localID: String
    let modificationDate: Date
    let original: UploadFile
    let motion: UploadFile?
    let sidecar: UploadFile?
    let fields: [String: String]
    let isVideo: Bool
    var livePhotoID: String?
    var motionChecksum: String?
    var stageID = UUID().uuidString
}

enum BackupError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

@MainActor enum DevicePhotos {
    static var authorization: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    static func albums() -> [DeviceAlbum] {
        guard [.authorized, .limited].contains(authorization) else { return [] }
        var values: [DeviceAlbum] = []
        for type in [PHAssetCollectionType.smartAlbum, .album] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                if assets.count > 0 {
                    values.append(DeviceAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album",
                                              count: assets.count, isShared: collection.assetCollectionSubtype == .albumCloudShared))
                }
            }
        }
        return values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func candidates(included: Set<String>, excluded: Set<String>) -> [String] {
        func ids(_ collections: Set<String>) -> Set<String> {
            var result = Set<String>()
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(collections), options: nil).enumerateObjects { collection, _, _ in
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                    if asset.mediaType == .image || asset.mediaType == .video { result.insert(asset.localIdentifier) }
                }
            }
            return result
        }
        return ids(included).subtracting(ids(excluded)).sorted()
    }

    static func modificationDate(for localID: String) -> Date? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject?.modificationDate
    }

    static func canRemove(_ localID: String, revision: Date) -> Bool {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject,
              asset.modificationDate == revision else { return false }
        // Keep adjusted, RAW+JPEG and auxiliary resources until all their variants
        // have verified server receipts. A plain original receipt cannot prove that.
        let resources = PHAssetResource.assetResources(for: asset)
        let originals = resources.filter { $0.type == .photo || $0.type == .video }
        return originals.count == 1 && resources.allSatisfy {
            $0.type == .photo || $0.type == .video || $0.type == .pairedVideo
        }
    }

    static func prepare(_ localID: String, directory: URL, allowCloud: Bool, cellularPhotos: Bool, cellularVideos: Bool,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedPhoto {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else {
            throw BackupError.message("This photo is no longer available to Ilyich. Check Photos access and retry.")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let type: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        let editedType: PHAssetResourceType = asset.mediaType == .video ? .fullSizeVideo : .fullSizePhoto
        // Back up the current full-size version when Photos has applied edits,
        // matching its visible image without rendering our own replacement.
        guard let original = resources.first(where: { $0.type == editedType }) ?? resources.first(where: { $0.type == type }) else {
            throw BackupError.message("Photos did not provide this asset’s full-size file. Nothing was marked as backed up.")
        }
        let motion = resources.first { $0.type == .fullSizePairedVideo } ?? resources.first { $0.type == .pairedVideo }
        if asset.mediaSubtypes.contains(.photoLive), motion == nil {
            throw BackupError.message("Photos did not provide the Live Photo video. Retry after it downloads from iCloud.")
        }
        // Apple's adjustment archives are not Lightroom XMP. Only attach actual XMP.
        let sidecar = resources.first { $0.originalFilename.lowercased().hasSuffix(".xmp") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = try await export(original, directory: directory, name: "original", allowCloud: allowCloud,
                                    allowCellular: asset.mediaType == .video ? cellularVideos : cellularPhotos, progress: progress)
        let video: UploadFile?
        if let motion { video = try await export(motion, directory: directory, name: "motion", allowCloud: allowCloud, allowCellular: cellularVideos, progress: progress) }
        else { video = nil }
        let xmp: UploadFile?
        if let sidecar { xmp = try await export(sidecar, directory: directory, name: "sidecar", allowCloud: allowCloud, allowCellular: cellularPhotos, progress: progress) }
        else { xmp = nil }
        let created = asset.creationDate ?? Date()
        let modified = asset.modificationDate ?? created
        return PreparedPhoto(localID: localID, modificationDate: modified, original: file, motion: video, sidecar: xmp,
                             fields: ["fileCreatedAt": created.ISO8601Format(), "fileModifiedAt": modified.ISO8601Format(),
                                      "isFavorite": String(asset.isFavorite), "duration": String(Int(asset.duration * 1000))],
                             isVideo: asset.mediaType == .video)
    }

    private static func export(_ resource: PHAssetResource, directory: URL, name: String, allowCloud: Bool, allowCellular: Bool,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> UploadFile {
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        options.progressHandler = progress
        do { try await PhotoResourceExport(destination: destination).write(resource, options: options) }
        catch {
            let details = error as NSError
            guard allowCloud, details.domain == PHPhotosErrorDomain,
                  details.code == PHPhotosError.networkAccessRequired.rawValue else { throw error }
            try Task.checkCancellation()
            options.isNetworkAccessAllowed = true
            try await PhotoResourceExport(destination: destination).write(resource, options: options, allowCellular: allowCellular)
        }
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        return UploadFile(url: destination, filename: resource.originalFilename,
                          contentType: UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream")
    }
}
