import CoreLocation
import Foundation
import Photos

/// One PhotoKit resource as the staging rules see it: its kind, its uniform type and its file name.
struct StagingResource: Hashable, Sendable {
    let type: PHAssetResourceType
    /// The resource's uniform type identifier, such as public.heic.
    let contentType: String
    let filename: String

    init(type: PHAssetResourceType, contentType: String, filename: String) {
        self.type = type; self.contentType = contentType; self.filename = filename
    }
}

/// Which resource is a phone photo's current full-size file.
enum CurrentResourceChoice: Equatable, Sendable {
    /// The resource at this index.
    case resource(Int)
    /// One of these originals, such as RAW and JPEG; Photos' content editing input names the one
    /// it shows.
    case byEditingInput([Int])
    /// Photos named no current file.
    case unidentified
}

/// What staging a phone photo for backup copies, decided from its resources alone. Every rule is
/// pure, so the backup's choices are tested without PhotoKit; PhotoKitAdapter applies them.
enum StagingRules {
    /// Edits Photos has applied, or a second original: an asset with any of them is adjusted, so it
    /// carries no mobile-app metadata (its cloud identity names the unedited source).
    static let adjustmentTypes: Set<PHAssetResourceType> = [.adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo,
                                                            .fullSizePhoto, .fullSizeVideo, .alternatePhoto]

    /// The current full-size version: the rendered edit when Photos has applied one, matching
    /// what Photos shows without rendering a replacement of our own; else the only original.
    static func currentResource(_ resources: [StagingResource], isVideo: Bool) -> CurrentResourceChoice {
        if let edited = resources.firstIndex(where: { $0.type == (isVideo ? .fullSizeVideo : .fullSizePhoto) }) { return .resource(edited) }
        let candidates = resources.indices.filter { index in
            let type = resources[index].type
            return isVideo ? type == .video : type == .photo || type == .alternatePhoto
        }
        if candidates.count == 1, let only = candidates.first { return .resource(only) }
        if !isVideo, candidates.count > 1 { return .byEditingInput(candidates) }
        return .unidentified
    }

    /// The candidate whose type is the one Photos' editing input reports, if exactly one is.
    static func resolve(_ candidates: [Int], in resources: [StagingResource], editingType: String) -> Int? {
        let matching = candidates.filter { resources[$0].contentType == editingType }
        return matching.count == 1 ? matching.first : nil
    }

    /// A Live Photo's motion: the edited video when there is one, else the original.
    static func motion(_ resources: [StagingResource]) -> Int? {
        resources.firstIndex { $0.type == .fullSizePairedVideo } ?? resources.firstIndex { $0.type == .pairedVideo }
    }

    /// The Lightroom sidecar. Only an actual .xmp file counts; Apple's adjustment archives aren't XMP.
    static func sidecar(_ resources: [StagingResource]) -> Int? {
        resources.firstIndex { $0.filename.lowercased().hasSuffix(".xmp") }
    }

    /// A Live Photo must come with its motion, or the item fails and backup moves on.
    static func requireMotion(isLive: Bool, motion: Int?) throws {
        if isLive, motion == nil { throw BackupError.item(livePhotoWithoutMotion) }
    }

    /// Whether Photos holds no edit of the asset, the only case where its cloud identifier is sent.
    static func isUnadjusted(_ types: [PHAssetResourceType]) -> Bool {
        !types.contains(where: adjustmentTypes.contains)
    }

    /// The upload's form fields for the asset's dates, favorite and duration.
    static func fields(created: Date, modified: Date, isFavorite: Bool, duration: TimeInterval) -> [String: String] {
        ["fileCreatedAt": created.ISO8601Format(), "fileModifiedAt": modified.ISO8601Format(),
         "isFavorite": String(isFavorite), "duration": String(Int(duration * 1000))]
    }

    /// The mobile-app metadata field, which associates an unedited source across devices by its
    /// cloud identifier. Nil when Photos gave no usable identifier. Photos exposes no public
    /// adjustment timestamp, so edited assets use checksums and receipts instead, and the caller
    /// asks only for unadjusted ones.
    static func mobileAppMetadata(cloudID: String?, created: Date, location: CLLocationCoordinate2D?) throws -> String? {
        guard let cloudID, !cloudID.hasSuffix(":") else { return nil }
        var value = ["iCloudId": cloudID, "createdAt": created.ISO8601Format()]
        if let location {
            value["latitude"] = String(location.latitude)
            value["longitude"] = String(location.longitude)
        }
        let data = try JSONSerialization.data(withJSONObject: [["key": "mobile-app", "value": value]])
        return String(decoding: data, as: UTF8.self)
    }

    /// The photos discovery queues: each one never confirmed, or confirmed at another revision.
    static func pending(_ candidates: [DeviceCandidate], confirmed: [String: Date]) -> [String] {
        candidates.filter { confirmed[$0.id] == nil || confirmed[$0.id] != $0.modified }.map(\.id).sorted()
    }

    static let unidentified = "Photos did not identify this asset’s current full-size file. Try downloading it in Photos first."
    static let livePhotoWithoutMotion = "Photos did not provide the Live Photo video. Retry after it downloads from iCloud."
}
