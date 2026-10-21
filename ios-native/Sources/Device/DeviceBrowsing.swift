import Foundation
@preconcurrency import Photos
import Synchronization

/// The photos one query found, newest first, read a range at a time. Reading is synchronous and
/// may be slow, so callers do it off the main thread.
protocol DevicePhotoPaging: Sendable {
    var count: Int { get }
    func photos(in range: Range<Int>) -> [LocalPhoto]
}

/// One reading of the phone's photos and videos, in the whole library or one album.
struct DevicePhotoQuery: Sendable {
    /// The album's identifier, or empty for the whole library.
    let album: String
    let paging: any DevicePhotoPaging
    var count: Int { paging.count }
}

/// A phone photo with what the upload queue shows of it.
struct DevicePhotoDetails: Sendable, Equatable {
    let photo: LocalPhoto
    /// The original file's name, when Photos knows it.
    let filename: String?
    /// The user albums holding it, unsorted.
    let albumTitles: [String]
}

/// What On this phone reads of the Photos library (PhotoKitAdapter implements it).
protocol DeviceBrowsing: Sendable {
    var authorization: PHAuthorizationStatus { get }
    func requestAccess() async -> DeviceAccess
    func albums() async -> [DeviceAlbum]
    func changes() -> AsyncStream<DeviceLibraryChange>
    /// The photos and videos, newest first, in `album` or the whole library when it is empty.
    func query(album: String) async -> DevicePhotoQuery
    func photos(_ query: DevicePhotoQuery, in range: Range<Int>) async -> [LocalPhoto]
}

/// What the phone-photo actions need of the Photos library (PhotoKitAdapter implements it).
protocol DevicePhotoActing: Sendable {
    var authorization: PHAuthorizationStatus { get }
    func perform(_ mutation: DeviceMutation) async -> DeviceMutationResult
    /// The photos among `ids` that Photos still has, in the order given.
    func photos(withIDs ids: [String]) async -> [LocalPhoto]
    /// The asset's revision now, if its content is what it was at `recorded`: unchanged, or changed
    /// only in ways that leave the photo itself alone, such as a favorite. Nil when it is gone or
    /// its content changed.
    func currentRevision(of localID: String, sameContentAs recorded: Date?) async -> AssetRevision?
}

/// Which revisions of an asset show the same content: those its modification date moved through
/// while only its metadata changed, as when it was favorited. Learnt from Photos' change details
/// while the observer runs; an edit, a revert or a removal forgets the asset.
struct ContentRevisions: Sendable {
    /// More changes than this in one notification are not looked into; their assets are forgotten.
    static let limit = 1_000
    private var equivalent: [DeviceAssetID: Set<AssetRevision>] = [:]

    mutating func apply(_ details: PhotoLibraryChangeDetails) {
        for id in details.removed { equivalent[id] = nil }
        for id in details.changed {
            guard let step = details.metadataOnly[id], let before = step.before, let after = step.after else {
                equivalent[id] = nil; continue
            }
            guard before != after else { continue }
            var known = equivalent[id] ?? []
            if !known.contains(before) { known = [before] }
            known.insert(after)
            equivalent[id] = known
        }
    }

    func sameContent(_ id: DeviceAssetID, _ a: AssetRevision?, _ b: AssetRevision?) -> Bool {
        if a == b { return true }
        guard let a, let b, let known = equivalent[id] else { return false }
        return known.contains(a) && known.contains(b)
    }
}

private struct NoPhotos: DevicePhotoPaging {
    var count: Int { 0 }
    func photos(in range: Range<Int>) -> [LocalPhoto] { [] }
}

/// A PhotoKit fetch result. Photos allows reading one from any thread.
private final class PhotoKitPaging: DevicePhotoPaging, @unchecked Sendable {
    private let result: PHFetchResult<PHAsset>
    init(_ result: PHFetchResult<PHAsset>) { self.result = result }
    var count: Int { result.count }
    func photos(in range: Range<Int>) -> [LocalPhoto] {
        let range = range.clamped(to: 0..<result.count)
        guard !range.isEmpty else { return [] }
        return result.objects(at: IndexSet(integersIn: range)).map(LocalPhoto.init)
    }
}

extension PhotoKitAdapter: DeviceBrowsing, DevicePhotoActing {
    /// Reads of a few assets, off the main thread and off the adapter's queue.
    private nonisolated static func read<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: body).value
    }

    nonisolated func query(album: String) async -> DevicePhotoQuery {
        guard Self.canRead(authorization) else { return DevicePhotoQuery(album: album, paging: NoPhotos()) }
        return await Self.read {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            let result: PHFetchResult<PHAsset>
            if !album.isEmpty, let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject {
                result = PHAsset.fetchAssets(in: collection, options: options)
            } else {
                result = PHAsset.fetchAssets(with: options)
            }
            return DevicePhotoQuery(album: album, paging: PhotoKitPaging(result))
        }
    }

    nonisolated func photos(_ query: DevicePhotoQuery, in range: Range<Int>) async -> [LocalPhoto] {
        let paging = query.paging
        return await Self.read { paging.photos(in: range) }
    }

    nonisolated func photos(withIDs ids: [String]) async -> [LocalPhoto] {
        guard !ids.isEmpty, Self.canRead(authorization) else { return [] }
        return await Self.read {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var byID: [String: LocalPhoto] = [:]
            fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = LocalPhoto(asset) }
            return ids.compactMap { byID[$0] }
        }
    }

    /// The asset with its original file's name and the user albums holding it, nil when it is gone.
    nonisolated func details(of localID: String) async -> DevicePhotoDetails? {
        guard Self.canRead(authorization) else { return nil }
        return await Self.read {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
            let filename = PHAssetResource.assetResources(for: asset)
                .first(where: { [.photo, .video, .alternatePhoto].contains($0.type) })?.originalFilename
            var titles: [String] = []
            PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { album, _, _ in
                if let title = album.localizedTitle { titles.append(title) }
            }
            return DevicePhotoDetails(photo: LocalPhoto(asset), filename: filename, albumTitles: titles)
        }
    }

    nonisolated func currentRevision(of localID: String, sameContentAs recorded: Date?) async -> AssetRevision? {
        let reader = stagingReader
        guard let found = await Self.read({ reader.candidates([localID]).first }) else { return nil }
        let current = found.modified.map(AssetRevision.init)
        let same = contentRevisions.withLock { $0.sameContent(DeviceAssetID(rawValue: localID), recorded.map(AssetRevision.init), current) }
        return same ? current : nil
    }

    /// Whether the asset still shows what it showed at `recorded`.
    nonisolated func contentUnchanged(of localID: String, since recorded: Date?) async -> Bool {
        let reader = stagingReader
        guard let found = await Self.read({ reader.candidates([localID]).first }) else { return false }
        return contentRevisions.withLock {
            $0.sameContent(DeviceAssetID(rawValue: localID), recorded.map(AssetRevision.init), found.modified.map(AssetRevision.init))
        }
    }
}
