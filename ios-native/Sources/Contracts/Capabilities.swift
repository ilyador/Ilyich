import Foundation

/// An action the viewer, the selection bar or the info sheet can offer for an asset.
enum AssetAction: String, CaseIterable, Hashable, Sendable {
    case favorite, archive, lock, trash, deletePermanently, restore
    case addToAlbum, albumCover, profilePhoto, sharedLink, stack
    case edit, findSimilar, cast, openInBrowser, comments
    case download, share, saveToPhotos
}

enum ActionAvailability: Hashable, Sendable {
    case offered
    /// Shown but unavailable, with the reason to give.
    case disabled(String)
    case hidden
}

/// What an asset's actions depend on besides the asset.
struct CapabilityContext: Sendable {
    /// The signed-in user's ID.
    let viewerID: String
    let authorization: AuthorizationSnapshot
    let features: ServerFeatures?
    let origin: AssetSourceID
    let castAvailable: Bool
    let hasLocalCopy: Bool
}
