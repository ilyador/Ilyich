import Foundation
import Photos
import Synchronization

/// PhotoKit itself, for PhotoKitAdapter, and the only code that calls PhotoKit's change APIs or
/// observes the library (scripts/check-single-engine.sh holds it to that). Every method may run on
/// any thread; the request methods run inside a change block, on Photos' own queue.
final class SystemPhotoKit: PhotoLibraryPerforming, AssetFetching {
    private let observer = Mutex<PhotoKitChangeObserver?>(nil)

    init() {}

    func authorizationStatus() -> PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func requestAuthorization() async -> PHAuthorizationStatus { await PHPhotoLibrary.requestAuthorization(for: .readWrite) }

    func startObserving(_ onChange: @escaping @Sendable (PhotoLibraryChangeDetails) -> Void) {
        let started = PhotoKitChangeObserver(onChange: onChange)
        let replaced = observer.withLock { current -> PhotoKitChangeObserver? in
            defer { current = started }
            return current
        }
        if let replaced { PHPhotoLibrary.shared().unregisterChangeObserver(replaced) }
        PHPhotoLibrary.shared().register(started)
    }

    func stopObserving() {
        let stopped = observer.withLock { current -> PhotoKitChangeObserver? in
            defer { current = nil }
            return current
        }
        if let stopped { PHPhotoLibrary.shared().unregisterChangeObserver(stopped) }
    }

    func performChanges(_ block: @escaping @Sendable () -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges(block)
    }

    func requestDeletion(of ids: [DeviceAssetID]) {
        PHAssetChangeRequest.deleteAssets(Self.fetch(ids))
    }

    func requestFavorite(_ isFavorite: Bool, for ids: [DeviceAssetID]) {
        Self.fetch(ids).enumerateObjects { asset, _, _ in PHAssetChangeRequest(for: asset).isFavorite = isFavorite }
    }

    func requestCreation(still: URL?, video: URL?, pairedVideo: URL?) -> DeviceAssetID? {
        let creation = PHAssetCreationRequest.forAsset()
        if let still { creation.addResource(with: .photo, fileURL: still, options: nil) }
        if let video { creation.addResource(with: .video, fileURL: video, options: nil) }
        if let pairedVideo { creation.addResource(with: .pairedVideo, fileURL: pairedVideo, options: nil) }
        return creation.placeholderForCreatedAsset.map { DeviceAssetID(rawValue: $0.localIdentifier) }
    }

    func states(of ids: [DeviceAssetID]) -> [DeviceAssetState] {
        guard !ids.isEmpty else { return [] }
        let fetched = Self.fetch(ids)
        return (0..<fetched.count).map { index in
            let asset = fetched.object(at: index)
            return DeviceAssetState(id: DeviceAssetID(rawValue: asset.localIdentifier), revision: asset.modificationDate.map { AssetRevision($0) },
                                    isFavorite: asset.isFavorite, canDelete: asset.canPerform(.delete),
                                    canEditProperties: asset.canPerform(.properties))
        }
    }

    private static func fetch(_ ids: [DeviceAssetID]) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
    }
}

/// The app's one PHPhotoLibraryChangeObserver. It keeps the fetch results Photos describes each
/// change against, and reports a change as identifiers. Photos calls it on a queue of its own.
final class PhotoKitChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable (PhotoLibraryChangeDetails) -> Void
    /// Guards the fetch results, the only state that changes.
    private let lock = NSLock()
    private var assets: PHFetchResult<PHAsset>
    private var collections: [PHFetchResult<PHAssetCollection>]

    init(onChange: @escaping @Sendable (PhotoLibraryChangeDetails) -> Void) {
        self.onChange = onChange
        assets = PHAsset.fetchAssets(with: nil)
        collections = [PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil),
                       PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)]
        super.init()
    }

    func photoLibraryDidChange(_ change: PHChange) {
        var details = lock.withLock { () -> PhotoLibraryChangeDetails in
            var details = PhotoLibraryChangeDetails()
            if let changes = change.changeDetails(for: assets) {
                assets = changes.fetchResultAfterChanges
                if changes.hasIncrementalChanges {
                    details.inserted = Self.ids(changes.insertedObjects)
                    details.removed = Self.ids(changes.removedObjects)
                    details.changed = Self.ids(changes.changedObjects)
                } else {
                    details.requiresFullReload = true
                }
            }
            for index in collections.indices {
                guard let changes = change.changeDetails(for: collections[index]) else { continue }
                collections[index] = changes.fetchResultAfterChanges
                details.albumsChanged = true
            }
            return details
        }
        // A change that names nothing kept here, such as photos added to an album, may still
        // matter to whoever reads albums.
        if details == PhotoLibraryChangeDetails() { details.albumsChanged = true }
        onChange(details)
    }

    private static func ids(_ assets: [PHAsset]) -> Set<DeviceAssetID> {
        Set(assets.map { DeviceAssetID(rawValue: $0.localIdentifier) })
    }
}
