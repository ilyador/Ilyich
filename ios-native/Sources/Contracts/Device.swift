import CryptoKit
import Foundation
import Photos

/// A PHAsset's localIdentifier, unchanged.
struct DeviceAssetID: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// A PHAssetCollection's localIdentifier, unchanged.
struct DeviceAlbumID: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// Photos access, with a generation that moves on every change, so work started under an older
/// grant can tell.
struct DeviceAccess: Hashable, Sendable {
    var status: PHAuthorizationStatus
    var generation: UInt64
}

/// How a phone photo is made of resources. Only a single original, or a Live Photo with its video
/// backed up, may ever be removed from the phone after backup.
enum ResourceShape: Hashable, Sendable {
    /// One photo or one video, nothing else.
    case singleOriginal
    /// One photo and its paired video.
    case livePhoto
    /// Edited in Photos: adjustments or rendered full-size versions.
    case edited
    /// More than one original, such as RAW and JPEG.
    case multipleOriginals
    /// Anything else, including a resource kind that doesn't match the asset's.
    case other

    private static let edits: Set<PHAssetResourceType> = [.adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo,
                                                          .adjustmentBasePairedVideo, .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo]

    /// Classifies an asset by its resource types. Edits come first, then extra originals; a shape
    /// is single or Live only when nothing else is present.
    static func classify(_ types: [PHAssetResourceType], isVideo: Bool) -> ResourceShape {
        if types.contains(where: edits.contains) { return .edited }
        let originals = types.filter { $0 == .photo || $0 == .video }
        if originals.count > 1 || types.contains(.alternatePhoto) { return .multipleOriginals }
        if isVideo { return types == [.video] ? .singleOriginal : .other }
        if types == [.photo] { return .singleOriginal }
        if types.count == 2, types.contains(.photo), types.contains(.pairedVideo) { return .livePhoto }
        return .other
    }
}

/// A phone photo as the device index publishes it.
struct DeviceAsset: Hashable, Sendable {
    struct Coordinate: Hashable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    let id: DeviceAssetID
    /// Nil when Photos reports no modification date.
    let revision: AssetRevision?
    let created: Date?
    let isVideo: Bool
    let isLive: Bool
    let isFavorite: Bool
    let location: Coordinate?
    let shape: ResourceShape
    let canDelete: Bool
    let canEditProperties: Bool
}

/// One coalesced burst of Photos library changes. The identifiers name assets to read again:
/// within one burst an asset may be inserted and then removed, so a reader asks Photos for each
/// one's state now rather than trusting which set it is in.
struct DeviceLibraryChange: Equatable, Sendable {
    var access: DeviceAccess
    var inserted: Set<DeviceAssetID> = []
    var removed: Set<DeviceAssetID> = []
    var changed: Set<DeviceAssetID> = []
    /// An album was added, removed or renamed, or Photos reported a change that names no asset,
    /// such as photos added to an album.
    var albumsChanged = false
    /// Photos gave no details, or access changed, so every reader starts over.
    var requiresFullReload = false

    /// Adds what one notification from Photos reported.
    mutating func merge(_ details: PhotoLibraryChangeDetails) {
        inserted.formUnion(details.inserted)
        removed.formUnion(details.removed)
        changed.formUnion(details.changed)
        albumsChanged = albumsChanged || details.albumsChanged
        requiresFullReload = requiresFullReload || details.requiresFullReload
    }
}

/// What one change notification from Photos reported, before bursts are merged.
struct PhotoLibraryChangeDetails: Hashable, Sendable {
    var inserted: Set<DeviceAssetID> = []
    var removed: Set<DeviceAssetID> = []
    var changed: Set<DeviceAssetID> = []
    var albumsChanged = false
    var requiresFullReload = false
}

/// A change to the Photos library. Deletion names the revision each asset must still have, and
/// favoriting may name some: if any differs, nothing is changed.
enum DeviceMutation: Hashable, Sendable {
    case delete([DeviceAssetID], expected: [DeviceAssetID: AssetRevision], origin: MutationOrigin)
    case setFavorite([DeviceAssetID], Bool, expected: [DeviceAssetID: AssetRevision])
    /// Saves files to Photos. A paired video makes the still a Live Photo.
    case create(still: URL?, video: URL?, pairedVideo: URL?, origin: MutationOrigin)
}

/// Who asked for a device mutation. Accounts are named by their digest, which the journal keeps.
enum MutationOrigin: Hashable, Sendable {
    case user
    case cleanup(scan: UUID, account: String)
    case saveFromServer(asset: String, account: String)
}

struct DeviceMutationResult: Hashable, Sendable {
    enum Outcome: Hashable, Sendable {
        case committed(affected: [DeviceAssetID], created: [DeviceAssetID])
        /// The user declined iOS's prompt. Not an error.
        case declined
        /// An asset changed or vanished since it was checked, so nothing was changed.
        case revisionChanged
        case notPermitted
        case failed(String)
        /// The app ended while Photos was applying it, and nothing now shows that it happened.
        /// Reconciled at the next launch; never applied again.
        case interrupted
    }

    /// The journal entry's ID. A change refused before Photos was asked has no entry.
    let id: UUID
    let mutation: DeviceMutation
    let outcome: Outcome
}

/// The phone's contribution to the merged timeline at one moment. Each month carries a digest of
/// what it shows, so a consumer reprojects only the months whose digest changed.
struct DeviceSnapshot: Sendable {
    struct Month: Equatable, Sendable {
        /// Phone-only photos of the month, newest first.
        let assets: [DeviceAsset]
        let digest: String

        init(assets: [DeviceAsset]) {
            self.assets = assets
            let text = assets.map { asset in
                [asset.id.rawValue, asset.revision.map { String($0.referenceSeconds.bitPattern) } ?? "-",
                 String(asset.isFavorite), String(asset.isLive), "\(asset.shape)"].joined(separator: "|")
            }.joined(separator: "\n")
            digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    let access: DeviceAccess
    let months: [MonthKey: Month]
    /// Phone photos already on the server, to the server asset each one matched.
    let matches: [DeviceAssetID: String]

    /// The months whose phone photos differ from an earlier snapshot's, including months that
    /// appeared or emptied.
    func changedMonths(since earlier: DeviceSnapshot) -> Set<MonthKey> {
        Set(months.keys).union(earlier.months.keys).filter { months[$0]?.digest != earlier.months[$0]?.digest }
    }
}
