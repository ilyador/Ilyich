import Foundation

/// A level of the library's shelves: the top, or a group one of its rows opens.
enum ShelfLevel: Hashable, Sendable {
    case root, people, albums, more, settings

    /// The top row that opens this group; nil for the top itself.
    var rowID: String? {
        switch self {
        case .root: nil
        case .people: "people"
        case .albums: "albums"
        case .more: "more"
        case .settings: "settings"
        }
    }
}

/// A collection the shelves show in the feed (REBUILD_ROADMAP.md N4): a person, an album, or one of
/// More's.
enum LibraryCollection: Hashable, Sendable {
    case person(Person)
    case album(Album)
    case recentlyTaken, recentlyAdded, videos, motion, lightroom, favorites, archive, trash

    /// More's collections, in the shelf's order.
    static let more: [LibraryCollection] = [.recentlyTaken, .recentlyAdded, .videos, .motion, .lightroom, .favorites, .archive, .trash]

    /// The shelf row's ID, which also names the layer and its pill (N6).
    var rowID: String {
        switch self {
        case .person(let person): "person-" + person.id
        case .album(let album): Self.albumRowID(album.id)
        case .recentlyTaken: "recent-taken"
        case .recentlyAdded: "recent-added"
        case .videos: "videos"
        case .motion: "motion"
        case .lightroom: "lightroom"
        case .favorites: "favorites"
        case .archive: "archive"
        case .trash: "trash"
        }
    }

    /// The row's title, which is also the filter's.
    var title: String {
        switch self {
        case .person(let person): person.name.isEmpty ? "Unnamed person" : person.name
        case .album(let album): album.albumName
        case .recentlyTaken: "Recently taken"
        case .recentlyAdded: "Recently added"
        case .videos: "Videos"
        case .motion: "Motion"
        case .lightroom: "Lightroom"
        case .favorites: "Favorites"
        case .archive: "Archive"
        case .trash: "Trash"
        }
    }

    var symbol: String {
        switch self {
        case .person: "person.crop.circle"
        case .album: "rectangle.stack"
        case .recentlyTaken: "camera"
        case .recentlyAdded: "clock.badge.checkmark"
        case .videos: "video"
        case .motion: "livephoto"
        case .lightroom: "slider.horizontal.3"
        case .favorites: "heart"
        case .archive: "archivebox"
        case .trash: "trash"
        }
    }

    static func albumRowID(_ id: String) -> String { "album-" + id }

    /// Whether the feed shows this collection now: it is one of the filters stacked.
    func isShown(in selection: ShelfSelection) -> Bool { selection.rows.contains(rowID) }
}

/// What a shelf row does (REBUILD_ROADMAP.md N4).
enum ShelfAction: Hashable, Sendable {
    /// Opens a group of the shelves in place.
    case open(ShelfLevel)
    /// Shows a collection in the feed at once. The shelves stay out while the finger is down, and
    /// a person or an album then rises into the filter tag.
    case show(LibraryCollection)
    /// Raises the Earth, or lowers it when it is up. The shelves go first.
    case places
    /// Opens a screen over the library. The shelves go first.
    case present(ModalRoute)
    /// Asks before something that can't be undone. The shelves go first.
    case confirm(Confirmation)
    /// Removes every filter and lowers the Earth (N6). The shelves go first.
    case clear
}

/// What the feed shows, as the shelves mark it: the rows of the filters stacked (N6).
struct ShelfSelection: Hashable, Sendable {
    var rows: Set<String> = []
}

/// The shelves' rows (REBUILD_ROADMAP.md N4), each with its ID, title, symbol, count, face or
/// cover, whether the feed shows it, and a typed action. The top level offers Clear while filters
/// apply (N6), People (where the server recognizes faces), Places (where it has the map), Albums,
/// More and Settings; People and Albums list the owner's order of them, then Manage people, or New
/// album and Manage albums; More lists its collections (Trash where the server keeps one, Lightroom
/// on the owner's fork), Browse more, and Shared files while any wait; Settings lists each
/// settings screen, then Sign out. Under a stack of filters People and Albums list only those in
/// its photos, an album counting them.
struct ShelfCatalog: Sendable {
    /// What the server offers; nil while it is unknown, when every row shows but Lightroom, which
    /// only the owner's fork can tell (a stock server develops nothing).
    var features: ServerFeatures?
    /// The people and albums in the owner's order.
    var people: [Person] = []
    var albums: [Album] = []
    var selection = ShelfSelection()
    /// Shared files are waiting to be looked at.
    var sharedFiles = false
    /// Filters apply, so the top level starts with Clear.
    var clearable = false
    /// The people and albums in the stacked feed's photos, counted by the index; nil when nothing
    /// narrows (no filter, or no readable index), when every one shows.
    var facets: ShelfFacets?

    /// The people the shelves list: those in the stacked feed's photos, and any chosen.
    var listedPeople: [Person] {
        guard let facets else { return people }
        return people.filter { facets.people[$0.id] != nil || selection.rows.contains(LibraryCollection.person($0).rowID) }
    }

    /// The albums the shelves list: those holding the stacked feed's photos, and any chosen.
    var listedAlbums: [Album] {
        guard let facets else { return albums }
        return albums.filter { facets.albums[$0.id] != nil || selection.rows.contains(LibraryCollection.albumRowID($0.id)) }
    }

    func rows(_ level: ShelfLevel) -> [LibraryShelfItem] {
        switch level {
        case .root:
            // Read on every move of a finger on the shelves, so each level lists only what it shows.
            let people = listedPeople, albums = listedAlbums
            var rows: [LibraryShelfItem] = []
            if clearable { rows.append(.init(id: "clear", title: "Clear", symbol: "xmark", action: .clear)) }
            if features?.facialRecognition != false {
                rows.append(.init(id: "people", title: "People", symbol: "person.2", detail: people.isEmpty ? nil : people.count.formatted(),
                                  action: .open(.people)))
            }
            if features?.map != false {
                rows.append(.init(id: "places", title: "Places", symbol: "globe.europe.africa", action: .places))
            }
            rows.append(.init(id: "albums", title: "Albums", symbol: "rectangle.stack", detail: albums.isEmpty ? nil : albums.count.formatted(),
                              action: .open(.albums)))
            rows.append(.init(id: "more", title: "More", symbol: "ellipsis", action: .open(.more)))
            rows.append(.init(id: "settings", title: "Settings", symbol: "gearshape", action: .open(.settings)))
            return rows
        case .people:
            return listedPeople.map { row(.person($0), person: $0) }
                + [.init(id: "all-people", title: "Manage people", symbol: "person.2", action: .present(.people))]
        case .albums:
            // Under a stack an album counts the stacked feed's photos it holds.
            return listedAlbums.map { album in
                row(.album(album), detail: (facets.map { $0.albums[album.id] ?? 0 } ?? album.assetCount).formatted(),
                    assetID: album.albumThumbnailAssetId)
            }
                + [.init(id: "new-album", title: "New album", symbol: "plus", action: .present(.newAlbum)),
                   .init(id: "all-albums", title: "Manage albums", symbol: "square.grid.2x2", action: .present(.albums))]
        case .more:
            var rows = LibraryCollection.more.filter { collection in
                switch collection {
                case .trash: features?.trash != false
                case .lightroom: features?.isFork == true
                default: true
                }
            }.map { row($0) }
            rows.append(.init(id: "browse-more", title: "Browse more", symbol: "square.grid.2x2", action: .present(.more)))
            if sharedFiles {
                rows.append(.init(id: "shared-files", title: "Shared files", symbol: "square.and.arrow.down", action: .present(.sharedFiles)))
            }
            return rows
        case .settings:
            return SettingsDestination.allCases.map { destination in
                LibraryShelfItem(id: "settings-" + destination.rawValue, title: destination.title, symbol: destination.symbol,
                                 action: .present(.settings(SettingsRoute(rawValue: destination.rawValue) ?? .root)))
            } + [.init(id: "sign-out", title: "Sign out", symbol: "rectangle.portrait.and.arrow.right", action: .confirm(.signOut))]
        }
    }

    private func row(_ collection: LibraryCollection, detail: String? = nil, person: Person? = nil, assetID: String? = nil) -> LibraryShelfItem {
        LibraryShelfItem(id: collection.rowID, title: collection.title, symbol: collection.symbol, detail: detail, person: person,
                         assetID: assetID, isSelected: collection.isShown(in: selection), action: .show(collection))
    }
}

extension LibraryFeedStore {
    /// What the feed shows, as the shelves mark it: every filter stacked.
    var shelfSelection: ShelfSelection { ShelfSelection(rows: Set(stack.layers.map(\.id))) }

    /// Shows a collection from the shelves on top of the filters already shown (N6). One the feed
    /// already shows stays as it is.
    func show(_ collection: LibraryCollection) {
        add(.collection(collection))
    }
}
