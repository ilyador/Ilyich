import Foundation

/// Everything presented above the library, one typed route each.
enum ModalRoute: Hashable, Sendable {
    /// The viewer, zooming out of the photo's grid cell.
    case viewer(ViewerRoute)
    /// A photo only on this phone, swiping through the phone's photos around it in the feed.
    case phoneViewer(LocalPhoto)
    case people
    case albums
    /// The More list, with the screens it pushes inside its own navigation.
    case more
    /// On this day, playing a memory straight away when the route names one.
    case memories(initialID: String?)
    /// Memories playing, presented by the screen that listed them.
    case memoryPlayer(MemoryPlayback)
    /// An album's comments and likes, or one photo's within it.
    case activity(album: String, asset: String?)
    case searchOptions
    case settings(SettingsRoute)
    /// Sharing the album shown in the feed.
    case albumSharing(Album, AlbumSharing)
    /// What can be done to the selected photos.
    case selectionActions(SelectionSnapshot)
    /// The album editor for a new album.
    case newAlbum
    case sharedFiles

    /// How the route comes onto the screen.
    var style: PresentationStyle {
        switch self {
        case .viewer: .zoom
        case .phoneViewer, .memoryPlayer: .cover
        default: .sheet
        }
    }
}

enum PresentationStyle: Hashable, Sendable {
    case sheet
    /// A full-screen cover.
    case cover
    /// The viewer's zoom out of its grid cell, which UIKit presents.
    case zoom
}

/// An album is shared by a link anyone can open, or with people who have accounts.
enum AlbumSharing: Hashable, Sendable {
    case link, people
}

/// The selected photos as they were when their actions were asked for.
struct SelectionSnapshot: Hashable, Sendable {
    let id = UUID()
    let assets: [Asset]
    /// Photos only on this phone.
    let local: [LocalPhoto]
}

/// Memories to play, and the one to start on.
struct MemoryPlayback: Hashable, Sendable {
    let memories: [Memory]
    let initialID: String
    private let id = UUID()

    init(memories: [Memory], initialID: String) {
        self.memories = memories
        self.initialID = initialID
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The one alert or question over the library.
enum LibraryAlert: Hashable, Sendable {
    case error(String)
    case confirm(Confirmation)
    /// Names the album made from the selected photos.
    case newAlbumFromSelection
}

/// A question asked before an action that can't be undone.
enum Confirmation: Hashable, Sendable {
    case signOut
    /// The selected photos go to Trash, or are deleted for good where the server keeps no Trash.
    case deleteSelection
}

/// Which photos the viewer pages through.
enum AssetSourceID: Hashable, Sendable {
    /// The months of the feed around the photo, or the photo alone when the feed has not loaded it.
    case feed
    case collection(String)
    case stack(String)
    /// Photos similar to this one.
    case similar(String)
    case single
    case locked
}

struct ViewerRoute: Hashable, Sendable {
    /// The photo the viewer opens on.
    let asset: Asset
    let source: AssetSourceID
    /// The album the photo was opened from, for its activity and cover actions.
    let albumContext: String?

    var initialAssetID: String { asset.id }
}

/// Each settings screen, or the root list. The other raw values are SettingsDestination's.
enum SettingsRoute: String, CaseIterable, Hashable, Sendable {
    case root, account, backup, readOnly, appearance, grid, viewer, network, notifications, server, diagnostics, about
}

/// What a screen or a link asks of the library. An intent runs once everything presented over
/// the library has closed, and only the newest one waiting runs.
enum NavigationIntent: Hashable, Sendable {
    /// Presents a screen over the library.
    case present(ModalRoute)
    /// Opens a photo in the viewer, in the album it was opened from.
    case openAsset(Asset, albumContext: String? = nil)
    /// Leaves any filter or search and scrolls the library to the photo.
    case showInTimeline(Asset)
    /// Raises the Earth, turned to the place.
    case exploreLocation(PlaceFocus)
    /// Shows one album's photos in the library.
    case showAlbum(Album)
    /// Shows one person's photos in the library.
    case showPerson(Person)
    /// Shows an alert over the library.
    case alert(LibraryAlert)
}

/// What covers the grid besides the screens presented over it. The shelves can come out while
/// the Earth is up, so each has its own flag.
struct LibraryOverlay: Hashable, Sendable {
    var shelves = false
    var earth = false
    /// The place the Earth turns to as it rises, or nil to leave it where it was.
    var earthFocus: PlaceFocus?

    var isEmpty: Bool { !shelves && !earth }
}
