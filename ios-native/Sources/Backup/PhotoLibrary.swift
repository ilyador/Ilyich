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
    case item(String)
    var errorDescription: String? {
        switch self { case .message(let message), .item(let message): message }
    }
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

    nonisolated static func candidates(included: Set<String>, excluded: Set<String>) -> [String] {
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

    nonisolated static func pendingCandidates(included: Set<String>, excluded: Set<String>, confirmed: [String: Date]) throws -> [String] {
        try Task.checkCancellation()
        let ids = candidates(included: included, excluded: excluded)
        var pending: [String] = []
        for start in stride(from: 0, to: ids.count, by: 250) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 250, ids.count)])
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
            for index in 0..<assets.count {
                let asset = assets.object(at: index)
                if confirmed[asset.localIdentifier] == nil || confirmed[asset.localIdentifier] != asset.modificationDate {
                    pending.append(asset.localIdentifier)
                }
            }
        }
        return pending.sorted()
    }

    static func modificationDate(for localID: String) -> Date? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject?.modificationDate
    }

    static func localFingerprint(id: String) async throws -> String {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw CocoaError(.fileNoSuchFile) }
        let resource = try await currentResource(for: asset, allowCloud: false, allowCellular: false) { _ in }
        try Task.checkCancellation()
        return try await PhotoResourceExport.checksum(resource)
    }

    static func currentResource(for asset: PHAsset, allowCloud: Bool, allowCellular: Bool,
                                        progress: @escaping @Sendable (Double) -> Void) async throws -> PHAssetResource {
        let resources = PHAssetResource.assetResources(for: asset)
        let video = asset.mediaType == .video
        if let edited = resources.first(where: { $0.type == (video ? .fullSizeVideo : .fullSizePhoto) }) { return edited }
        let candidates = resources.filter { video ? $0.type == .video : $0.type == .photo || $0.type == .alternatePhoto }
        if candidates.count == 1, let only = candidates.first { return only }
        if !video, candidates.count > 1 {
            let type = try await PhotoCurrentRepresentation(asset: asset).contentType(allowCloud: allowCloud, allowCellular: allowCellular, progress: progress)
            let matching = candidates.filter { $0.contentType.identifier == type }
            if matching.count == 1, let current = matching.first { return current }
        }
        throw BackupError.item("Photos did not identify this asset’s current full-size file. Try downloading it in Photos first.")
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
        guard [.authorized, .limited].contains(authorization) else {
            throw BackupError.message("Photos access was removed. Allow access in Settings before resuming backup.")
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else {
            throw BackupError.item("This photo is no longer available to Ilyich. Check Photos access and retry.")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        // Back up the current full-size version when Photos has applied edits,
        // matching its visible image without rendering our own replacement.
        let original = try await currentResource(for: asset, allowCloud: allowCloud,
            allowCellular: asset.mediaType == .video ? cellularVideos : cellularPhotos, progress: progress)
        let motion = resources.first { $0.type == .fullSizePairedVideo } ?? resources.first { $0.type == .pairedVideo }
        if asset.mediaSubtypes.contains(.photoLive), motion == nil {
            throw BackupError.item("Photos did not provide the Live Photo video. Retry after it downloads from iCloud.")
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
        var fields = ["fileCreatedAt": created.ISO8601Format(), "fileModifiedAt": modified.ISO8601Format(),
                      "isFavorite": String(asset.isFavorite), "duration": String(Int(asset.duration * 1000))]
        // Cloud identifiers associate the unchanged source across devices. Photos
        // exposes no public adjustment timestamp, so edited assets use checksums
        // and receipts instead of claiming an imprecise cloud-identity match.
        let adjusted = resources.contains { [.adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo,
                                             .fullSizePhoto, .fullSizeVideo, .alternatePhoto].contains($0.type) }
        if !adjusted {
            let cloudID = try await UploadBody.work {
                let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [localID])
                return (try? mappings[localID]?.get())?.stringValue
            }
            if let cloudID, !cloudID.hasSuffix(":") {
                var value = ["iCloudId": cloudID, "createdAt": created.ISO8601Format()]
                if let location = asset.location {
                    value["latitude"] = String(location.coordinate.latitude)
                    value["longitude"] = String(location.coordinate.longitude)
                }
                let data = try JSONSerialization.data(withJSONObject: [["key": "mobile-app", "value": value]])
                fields["metadata"] = String(decoding: data, as: UTF8.self)
            }
        }
        return PreparedPhoto(localID: localID, modificationDate: modified, original: file, motion: video, sidecar: xmp,
                             fields: fields,
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
                          contentType: resource.contentType.preferredMIMEType ?? "application/octet-stream")
    }
}
