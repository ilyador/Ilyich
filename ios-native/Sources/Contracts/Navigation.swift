import Foundation

/// Everything presented above the library, one typed route each.
enum ModalRoute: Hashable, Sendable {
    case viewer(ViewerRoute)
    case phoneViewer(DeviceAssetID)
    case people
    case albums
    /// The More list, then the screens pushed from it, by name.
    case more(path: [String])
    case memories(initialID: String?)
    case activity(album: String, asset: String?)
    case searchOptions
    case settings(SettingsRoute)
    case albumEditor(album: String)
    case albumSharing(album: String)
    /// Actions for a selection of server asset IDs.
    case selectionActions(Set<String>)
    case newAlbum
    case sharedFiles
    case confirm(Confirmation)
}

/// A question asked before an action that can't be undone.
enum Confirmation: Hashable, Sendable {
    case signOut
    case delete(Set<String>, permanently: Bool)
    case emptyTrash
}

/// Which photos the viewer pages through.
enum AssetSourceID: Hashable, Sendable {
    /// The feed that opened it.
    case feed
    case collection(String)
    case stack(String)
    /// Photos similar to this one.
    case similar(String)
    case single
    case locked
}

struct ViewerRoute: Hashable, Sendable {
    let initialAssetID: String
    let source: AssetSourceID
    /// The album the photo was opened from, for its activity and cover actions.
    let albumContext: String?
}

/// Each settings screen, from the root list. Read-only mode has its own screen, as it has had
/// since build 3040055.
enum SettingsRoute: String, CaseIterable, Hashable, Sendable {
    case root, account, backup, readOnly, appearance, grid, network, notifications, server, diagnostics, about
}

enum NavigationIntent: Hashable, Sendable {
    case present(ModalRoute)
    case openAsset(String)
    case showInTimeline(String)
    case exploreLocation(latitude: Double, longitude: Double)
    case apply(LibraryQuery)
    case openShelf
}

/// What covers the grid.
enum LibraryOverlay: Hashable, Sendable {
    case none, shelves, earth
}
