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

    /// The shelf row's ID. A person or an album rises into the filter tag by its prefix.
    var rowID: String {
        switch self {
        case .person(let person): "person-" + person.id
        case .album(let album): "album-" + album.id
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

    /// Whether the feed shows this collection now.
    func isShown(in selection: ShelfSelection) -> Bool {
        switch self {
        case .person(let person): selection.person == person.id
        case .album(let album): selection.album == album.id
        case .recentlyTaken, .recentlyAdded, .lightroom: selection.filterTitle == title
        case .videos: selection.filterTitle == title && selection.mediaType == "VIDEO"
        case .motion: selection.filterTitle == title && selection.motion
        case .favorites: selection.favorite
        case .archive: selection.archive
        case .trash: selection.trash
        }
    }
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
}

/// What the feed shows, as the shelves mark it.
struct ShelfSelection: Hashable, Sendable {
    var person: String?
    var album: String?
    var filterTitle: String?
    /// The media type a metadata filter keeps, such as VIDEO.
    var mediaType: String?
    var motion = false
    var favorite = false
    var archive = false
    var trash = false
}

/// The shelves' rows (REBUILD_ROADMAP.md N4), each with its ID, title, symbol, count, face or
/// cover, whether the feed shows it, and a typed action. The top level offers People (where the
/// server recognizes faces), Places (where it has the map), Albums, More and Settings; People and
/// Albums list the owner's order of them, then Manage people, or New album and Manage albums; More
/// lists its collections (Trash where the server keeps one), Browse more, and Shared files while
/// any wait; Settings lists each settings screen, then Sign out.
struct ShelfCatalog: Sendable {
    /// What the server offers; nil while it is unknown, when every row shows.
    var features: ServerFeatures?
    /// The people and albums in the owner's order.
    var people: [Person] = []
    var albums: [Album] = []
    var selection = ShelfSelection()
    /// Shared files are waiting to be looked at.
    var sharedFiles = false

    func rows(_ level: ShelfLevel) -> [LibraryShelfItem] {
        switch level {
        case .root:
            var rows: [LibraryShelfItem] = []
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
            return people.map { row(.person($0), person: $0) }
                + [.init(id: "all-people", title: "Manage people", symbol: "person.2", action: .present(.people))]
        case .albums:
            return albums.map { row(.album($0), detail: $0.assetCount.formatted(), assetID: $0.albumThumbnailAssetId) }
                + [.init(id: "new-album", title: "New album", symbol: "plus", action: .present(.newAlbum)),
                   .init(id: "all-albums", title: "Manage albums", symbol: "square.grid.2x2", action: .present(.albums))]
        case .more:
            var rows = LibraryCollection.more.filter { $0 != .trash || features?.trash != false }.map { row($0) }
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
    /// What the feed shows, as the shelves mark it.
    var shelfSelection: ShelfSelection {
        ShelfSelection(person: feedQuery.predicates.people.first, album: feedQuery.predicates.albums.first, filterTitle: filterTitle,
                       mediaType: searchFilter.type?.eq, motion: searchFilter.isMotion?.eq == true,
                       favorite: feedQuery.predicates.favorite == true, archive: feedQuery.visibility == .archive,
                       trash: feedQuery.trash == .trashed)
    }

    /// Shows a collection from the shelves. A person or an album the feed already shows stays as
    /// it is.
    func show(_ collection: LibraryCollection) {
        switch collection {
        case .person(let person): if feedQuery.predicates.people.first != person.id { setPerson(person) }
        case .album(let album): if feedQuery.predicates.albums.first != album.id { setAlbum(album) }
        case .recentlyTaken: setFeed(.recentlyTaken, title: collection.title)
        case .recentlyAdded: setFeed(.recentlyAdded, title: collection.title)
        case .videos: setMetadataFilter(SearchFilter(type: StringFilter(eq: "VIDEO"), visibility: StringFilter(eq: "timeline")), title: collection.title)
        case .motion: setMetadataFilter(SearchFilter(isMotion: BoolFilter(eq: true), visibility: StringFilter(eq: "timeline")), title: collection.title)
        case .lightroom: setDeveloped(title: collection.title)
        case .favorites: setFeed(.favorites, title: collection.title)
        case .archive: setFeed(.archive, title: collection.title)
        case .trash: setFeed(.trash, title: collection.title)
        }
    }
}
