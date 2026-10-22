import Foundation
import Photos

/// The synchronous Photos reads a cleanup check makes, which tests fake. Safe on any thread;
/// PhotoKitCleanupDevice runs them off the adapter's queue and the caller's thread.
protocol CleanupAssetReading: Sendable {
    /// The assets among `ids` that Photos still has, each with how it is made, in no particular order.
    func cleanupAssets(_ ids: [DeviceAssetID]) -> [DeviceAsset]
    /// The photos and videos in any of the albums.
    func members(of albumIDs: Set<String>) -> Set<String>
}

/// What CleanupService asks of the phone (architecture section 6, DS2, DS3, DS7 and DS8).
protocol CleanupDevice: Sendable {
    /// Photos access now, with its generation.
    func access() async -> DeviceAccess
    /// The assets among `ids` that Photos still has.
    func assets(_ ids: [DeviceAssetID]) async throws -> [DeviceAsset]
    /// The photos and videos in any of the albums, read now.
    func members(of albumIDs: Set<String>) async throws -> Set<String>
    /// Applies a change through the adapter, which journals it and checks it again inside its block.
    func perform(_ mutation: DeviceMutation) async -> DeviceMutationResult
    /// The library's changes from now on.
    func changes() -> AsyncStream<DeviceLibraryChange>
}

/// CleanupDevice over the app's one Photos adapter.
struct PhotoKitCleanupDevice: CleanupDevice {
    let adapter: PhotoKitAdapter
    let reader: any CleanupAssetReading

    func access() async -> DeviceAccess { await adapter.refreshAccess() }

    func assets(_ ids: [DeviceAssetID]) async throws -> [DeviceAsset] {
        let reader = reader
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return reader.cleanupAssets(ids)
        }.value
    }

    func members(of albumIDs: Set<String>) async throws -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        let reader = reader
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return reader.members(of: albumIDs)
        }.value
    }

    func perform(_ mutation: DeviceMutation) async -> DeviceMutationResult { await adapter.perform(mutation) }

    func changes() -> AsyncStream<DeviceLibraryChange> { adapter.changes() }
}

extension SystemPhotoKit: CleanupAssetReading {
    func cleanupAssets(_ ids: [DeviceAssetID]) -> [DeviceAsset] {
        guard !ids.isEmpty else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
        return (0..<fetched.count).map { index in
            let asset = fetched.object(at: index)
            let isVideo = asset.mediaType == .video
            let shape = ResourceShape.classify(PHAssetResource.assetResources(for: asset).map(\.type), isVideo: isVideo)
            return DeviceAsset(id: DeviceAssetID(rawValue: asset.localIdentifier), revision: asset.modificationDate.map(AssetRevision.init),
                               created: asset.creationDate, isVideo: isVideo, isLive: asset.mediaSubtypes.contains(.photoLive),
                               isFavorite: asset.isFavorite,
                               location: asset.location.map { DeviceAsset.Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                               shape: shape, canDelete: asset.canPerform(.delete), canEditProperties: asset.canPerform(.properties))
        }
    }
}
