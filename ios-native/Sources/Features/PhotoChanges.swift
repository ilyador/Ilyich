import Photos

/// PhotoKit runs change blocks on its own queue. A block written inside a main-actor method
/// inherits that isolation and traps when PhotoKit calls it, so these blocks are built here,
/// outside any actor, from identifiers rather than objects.
enum PhotoChanges {
    nonisolated static func delete(_ ids: [String]) -> @Sendable () -> Void {
        { PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)) }
    }

    nonisolated static func favorite(_ ids: [String], _ value: Bool) -> @Sendable () -> Void {
        {
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
                PHAssetChangeRequest(for: asset).isFavorite = value
            }
        }
    }
}
